import Foundation
import AVFoundation

/// Re-encodes an asset (or composition) to MP4 using an AVAssetReader -> AVAssetWriter
/// pipeline. This gives explicit control over codec, bitrate, and audio sample rate.
/// On Apple Silicon, VideoToolbox routes H.264/HEVC encoding through the hardware media
/// engine automatically, so this path is hardware-accelerated.
enum ReencodeEngine {

    static func encode(asset: AVAsset,
                       timeRange: CMTimeRange?,
                       to outputURL: URL,
                       settings: EncodeSettings,
                       progress: @escaping @MainActor (Double) -> Void) async throws {

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw VideoError.noVideoTrack(outputURL) }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Normalize per-source rotation/size into one render space.
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        let renderSize = videoComposition.renderSize
        let frameDuration = videoComposition.frameDuration
        let fps = frameDuration.seconds > 0 ? 1.0 / frameDuration.seconds : 30.0

        let fullDuration = try await asset.load(.duration)
        let range = timeRange ?? CMTimeRange(start: .zero, duration: fullDuration)
        let totalSeconds = range.duration.seconds

        // MARK: Reader
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoError.compositionFailed }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); audioOutput = out }
        }

        // MARK: Writer
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(settings.videoBitrateMbps * 1_000_000),
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: compression
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoError.exportSessionUnavailable }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: Double(settings.audioSampleRate),
                AVEncoderBitRateKey: settings.audioBitrateKbps * 1000
            ])
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) { writer.add(ai); audioInput = ai }
        }

        // MARK: Run
        guard reader.startReading() else {
            throw VideoError.exportFailed(reader.error?.localizedDescription ?? "reader failed to start")
        }
        guard writer.startWriting() else {
            throw VideoError.exportFailed(writer.error?.localizedDescription ?? "writer failed to start")
        }
        writer.startSession(atSourceTime: range.start)

        async let videoDone: Void = transfer(
            from: videoOutput, to: videoInput, on: DispatchQueue(label: "reencode.video"),
            startSeconds: range.start.seconds, totalSeconds: totalSeconds, progress: progress)

        if let audioOutput, let audioInput {
            async let audioDone: Void = transfer(
                from: audioOutput, to: audioInput, on: DispatchQueue(label: "reencode.audio"),
                startSeconds: nil, totalSeconds: totalSeconds, progress: nil)
            _ = await (videoDone, audioDone)
        } else {
            _ = await videoDone
        }

        if reader.status == .failed {
            throw VideoError.exportFailed(reader.error?.localizedDescription ?? "read error")
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw VideoError.exportFailed(writer.error?.localizedDescription ?? "write error")
        }
        await progress(1.0)
    }

    /// Pumps sample buffers from a reader output into a writer input until exhausted.
    private static func transfer(from output: AVAssetReaderOutput,
                                 to input: AVAssetWriterInput,
                                 on queue: DispatchQueue,
                                 startSeconds: Double?,
                                 totalSeconds: Double,
                                 progress: (@MainActor (Double) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    input.append(buffer)
                    if let progress, let startSeconds, totalSeconds > 0 {
                        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        let p = min(max((pts - startSeconds) / totalSeconds, 0), 1)
                        Task { @MainActor in progress(p) }
                    }
                }
            }
        }
    }
}
