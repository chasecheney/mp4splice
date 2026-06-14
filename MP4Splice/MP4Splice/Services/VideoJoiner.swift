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

        if reencode {
            try await joinReencoding(urls: urls, to: outputURL, settings: settings, progress: progress)
        } else {
            try await joinPassthrough(urls: urls, to: outputURL, progress: progress)
        }
    }

    // MARK: - Passthrough (lossless remux, same-format inputs)

    private static func joinPassthrough(urls: [URL],
                                        to outputURL: URL,
                                        progress: @escaping @MainActor (Double) -> Void) async throws {
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

            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoError.noVideoTrack(url)
            }
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first, let audioTrack {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = cursor + duration
        }

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

    // MARK: - Re-encode (scales each clip to a common canvas)

    private static func joinReencoding(urls: [URL],
                                       to outputURL: URL,
                                       settings: EncodeSettings,
                                       progress: @escaping @MainActor (Double) -> Void) async throws {
        // Output canvas: target height, aspect taken from the first clip.
        let firstOriented = try await orientedSize(of: urls[0])
        let aspect = firstOriented.height > 0 ? firstOriented.width / firstOriented.height : 16.0 / 9.0
        var canvasH = settings.resolution.targetHeight
        var canvasW = Int((Double(canvasH) * aspect).rounded())
        canvasW -= canvasW % 2
        canvasH -= canvasH % 2
        let renderSize = CGSize(width: canvasW, height: canvasH)

        let composition = AVMutableComposition()
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoError.noVideoTrack(url)
            }
            // Each clip gets its own composition track so it can be transformed independently.
            guard let compVideo = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoError.compositionFailed
            }
            try compVideo.insertTimeRange(range, of: sourceVideo, at: cursor)

            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first, let audioTrack {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            let natural = try await sourceVideo.load(.naturalSize)
            let preferred = try await sourceVideo.load(.preferredTransform)
            let transform = fitTransform(naturalSize: natural, preferred: preferred, into: renderSize)

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            layer.setTransform(transform, at: cursor)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            cursor = cursor + duration
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = settings.frameRate.frameDuration
        videoComposition.instructions = instructions

        try await ReencodeEngine.encode(
            asset: composition, videoComposition: videoComposition,
            timeRange: nil, to: outputURL, settings: settings, progress: progress)
    }

    // MARK: - Geometry helpers

    /// Display size of a file's first video track with its preferred transform applied.
    private static func orientedSize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.noVideoTrack(url)
        }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let r = natural.applying(preferred)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// Builds a transform that orients a clip, scales it to fit `renderSize` preserving
    /// aspect ratio, and centers it (letterboxing as needed).
    private static func fitTransform(naturalSize: CGSize,
                                     preferred: CGAffineTransform,
                                     into renderSize: CGSize) -> CGAffineTransform {
        let oriented = naturalSize.applying(preferred)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { return preferred }

        let scale = min(renderSize.width / orientedSize.width,
                        renderSize.height / orientedSize.height)
        let scaledW = orientedSize.width * scale
        let scaledH = orientedSize.height * scale
        let tx = (renderSize.width - scaledW) / 2
        let ty = (renderSize.height - scaledH) / 2

        return preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }
}
