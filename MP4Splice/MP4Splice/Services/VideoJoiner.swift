import Foundation
import AVFoundation

/// Concatenates multiple media files into a single MP4 using AVFoundation.
/// Passthrough export keeps the join lossless when the inputs share a compatible format.
enum VideoJoiner {

    static func join(urls: [URL],
                     to outputURL: URL,
                     reencode: Bool = false,
                     settings: EncodeSettings = EncodeSettings(),
                     progress: @escaping @MainActor (Double) -> Void) async throws {
        guard !urls.isEmpty else { throw VideoError.noInputs }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.compositionFailed
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideo = videoTracks.first else {
                throw VideoError.noVideoTrack(url)
            }
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let sourceAudio = audioTracks.first, let audioTrack {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            cursor = cursor + duration
        }

        // Re-encode path: explicit codec/bitrate control via AVAssetWriter (hardware-accelerated).
        if reencode {
            try await ReencodeEngine.encode(
                asset: composition, timeRange: nil, to: outputURL,
                settings: settings, progress: progress)
            return
        }

        // Default path: lossless passthrough remux.
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoError.exportSessionUnavailable
        }

        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        try await ExportHelper.run(session, progress: progress)
    }
}
