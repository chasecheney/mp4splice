import Foundation
import AVFoundation

/// Re-encodes an asset (or composition) to MP4 using an AVAssetReader -> AVAssetWriter
/// pipeline. This gives explicit control over codec, bitrate, and audio sample rate.
/// On Apple Silicon, VideoToolbox routes H.264/HEVC encoding through the hardware media
/// engine automatically, so this path is hardware-accelerated.
enum ReencodeEngine {

    /// One stretch of a source clip's audio, placed at `at` on the output timeline.
    /// `track` nil = the clip has no audio; the stretch is filled with silence.
    struct AudioPiece {
        let asset: AVAsset          // held here: AVAssetTrack.asset is a weak reference
        let track: AVAssetTrack?
        let range: CMTimeRange
        let at: CMTime
    }

    /// `audioPieces`: when given, audio is read piece by piece straight from the source
    /// clips instead of from `asset`'s audio tracks (see AudioPieceFeeder for why).
    static func encode(asset: AVAsset,
                       videoComposition providedComposition: AVMutableVideoComposition? = nil,
                       timeRange: CMTimeRange?,
                       audioPieces: [AudioPiece]? = nil,
                       to outputURL: URL,
                       settings: EncodeSettings,
                       progress: @escaping @MainActor (Double) -> Void) async throws {

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw VideoError.noVideoTrack(outputURL) }
        let audioTracks = audioPieces == nil ? try await asset.loadTracks(withMediaType: .audio) : []
        let feeder = audioPieces.flatMap { pieces in
            pieces.contains { $0.track != nil }
                ? AudioPieceFeeder(pieces: pieces, sampleRate: Double(settings.audioSampleRate)) : nil
        }

        let videoComposition: AVMutableVideoComposition
        let outWidth: Int
        let outHeight: Int

        if let providedComposition {
            // Caller already built a composition sized to the desired output (join path).
            videoComposition = providedComposition
            outWidth = Int(providedComposition.renderSize.width)
            outHeight = Int(providedComposition.renderSize.height)
        } else {
            // Single-source path (split): normalize rotation/size, then scale via the writer.
            let vc = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            vc.frameDuration = settings.frameRate.frameDuration
            let renderSize = vc.renderSize
            let aspect = renderSize.height > 0 ? renderSize.width / renderSize.height : 16.0 / 9.0
            var h = settings.resolution.targetHeight
            var w = Int((Double(h) * aspect).rounded())
            w -= w % 2
            h -= h % 2
            videoComposition = vc
            outWidth = w
            outHeight = h
        }
        let outFps = settings.frameRate.fps

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
            AVVideoExpectedSourceFrameRateKey: Int(outFps.rounded())
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        // VideoToolbox scales incoming frames to these dimensions during encode.
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoScalingModeKey: settings.fillFrame ? AVVideoScalingModeResizeAspectFill : AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoError.exportSessionUnavailable }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil || feeder != nil {
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

        // Cancelling only raises a flag. Each pump sees it between samples and stops; the
        // reader is torn down here once both have returned. Calling cancelReading() from
        // another thread while a pump is inside copyNextSampleBuffer() frees the reader
        // under it (EXC_BAD_ACCESS on Stop, 2026-11-01).
        let cancel = CancelFlag()
        let videoSource = UncheckedBox(videoOutput as AVAssetReaderOutput)
        let audioSource: UncheckedBox<() -> CMSampleBuffer?>? = feeder.map { f in
            UncheckedBox({ f.next(cancel) })
        } ?? audioOutput.map { out in UncheckedBox({ out.copyNextSampleBuffer() }) }
        await withTaskCancellationHandler {
            async let videoDone: Void = transfer(
                Pump(next: { videoSource.value.copyNextSampleBuffer() }, input: videoInput),
                on: DispatchQueue(label: "reencode.video"), cancel: cancel,
                startSeconds: range.start.seconds, totalSeconds: totalSeconds, progress: progress)

            if let audioSource, let audioInput {
                async let audioDone: Void = transfer(
                    Pump(next: audioSource.value, input: audioInput),
                    on: DispatchQueue(label: "reencode.audio"), cancel: cancel,
                    startSeconds: nil, totalSeconds: totalSeconds, progress: nil)
                _ = await (videoDone, audioDone)
            } else {
                _ = await videoDone
            }
        } onCancel: {
            cancel.set()
        }

        if Task.isCancelled || cancel.isSet {
            reader.cancelReading()
            writer.cancelWriting()
            throw VideoError.cancelled
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

    /// Wraps non-Sendable AVFoundation objects so they can cross into the
    /// `@Sendable` media-data callback. Access is serialized onto a single queue,
    /// so the unchecked Sendable conformance is safe in practice.
    private struct UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Thread-safe one-way switch for cancelling the pumps.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Pumps sample buffers from `next` into a writer input until it returns nil or the
    /// job is cancelled.
    /// A sample source and the writer input it feeds, handed to the pump's queue.
    private struct Pump: @unchecked Sendable {
        let next: () -> CMSampleBuffer?
        let input: AVAssetWriterInput
    }

    private static func transfer(_ pump: Pump,
                                 on queue: DispatchQueue,
                                 cancel: CancelFlag,
                                 startSeconds: Double?,
                                 totalSeconds: Double,
                                 progress: (@MainActor (Double) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let input = pump.input
            let finished = CancelFlag()   // set once; the requester may call back again
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished.isSet else { return }
                while input.isReadyForMoreMediaData {
                    guard !cancel.isSet, let buffer = pump.next() else {
                        finished.set()
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

/// Supplies a join's audio piece by piece, read straight from each source clip.
///
/// Reading audio through an AVMutableComposition whose pieces are cut at loop boundaries
/// can hang inside copyNextSampleBuffer() for good: it depends on the exact cut times and
/// on where a piece lands on the timeline, so no rounding of the times avoids it reliably
/// (2026-11-01, on real story exports: 15 clips, 23 pieces, stuck at 19–29%). A reader
/// over a plain range of one file is the well-trodden path.
///
/// Every buffer is converted to one PCM format and placed on a sample clock that follows
/// the video pieces exactly: silence fills audio that is missing or ends early, and audio
/// that runs past a piece's end is trimmed, so sound stays in sync at every cut.
/// Used only from the audio pump's serial queue.
final class AudioPieceFeeder {
    private let pieces: [ReencodeEngine.AudioPiece]
    private let rate: Double
    private let channels = 2
    private let bytesPerFrame = 4            // 16-bit interleaved stereo
    private let format: CMAudioFormatDescription
    private let outputSettings: [String: Any]

    private var index = 0
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var opened = false
    private var pending: CMSampleBuffer?
    private var clock: Int64 = 0             // frames handed out so far
    private static let chunk: Int64 = 4096   // silence buffer size, in frames

    init?(pieces: [ReencodeEngine.AudioPiece], sampleRate: Double) {
        self.pieces = pieces
        self.rate = sampleRate
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var desc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &desc) == noErr, let desc else { return nil }
        format = desc
        outputSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private func frames(_ t: CMTime) -> Int64 { Int64((t.seconds * rate).rounded()) }

    /// The next buffer of output audio, or nil when every piece is done.
    func next(_ cancel: ReencodeEngine.CancelFlag) -> CMSampleBuffer? {
        while index < pieces.count, !cancel.isSet {
            let piece = pieces[index]
            let start = frames(piece.at), end = frames(piece.at + piece.range.duration)
            if clock < start { return silence(min(start - clock, Self.chunk)) }
            if clock >= end { closePiece(); continue }
            if !opened { openPiece(piece) }

            guard let buffer = pending ?? output?.copyNextSampleBuffer() else {
                // No audio (or it ended early): silence to the end of the piece.
                closeReader()
                return silence(min(end - clock, Self.chunk))
            }
            pending = nil
            let count = Int64(CMSampleBufferGetNumSamples(buffer))
            let pos = start + frames(CMSampleBufferGetPresentationTimeStamp(buffer) - piece.range.start)
            if pos > clock + 1 {                       // a gap inside the clip's audio
                pending = buffer
                return silence(min(pos - clock, end - clock, Self.chunk))
            }
            let drop = max(clock - pos, 0)             // overlap with what's already out
            let take = min(count - drop, end - clock)
            guard take > 0, let slice = retimed(buffer, from: drop, count: take) else { continue }
            clock += take
            return slice
        }
        closeReader()
        return nil
    }

    private func openPiece(_ piece: ReencodeEngine.AudioPiece) {
        opened = true
        guard let track = piece.track, let r = try? AVAssetReader(asset: piece.asset) else { return }
        r.timeRange = piece.range
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return }
        r.add(out)
        guard r.startReading() else { return }
        reader = r
        output = out
    }

    private func closeReader() {
        if reader?.status == .reading { reader?.cancelReading() }   // same queue as the reads
        reader = nil
        output = nil
        pending = nil
    }

    private func closePiece() {
        closeReader()
        opened = false
        index += 1
    }

    /// `count` frames of `buffer` starting at frame `from`, stamped at the current clock.
    private func retimed(_ buffer: CMSampleBuffer, from: Int64, count: Int64) -> CMSampleBuffer? {
        var slice: CMSampleBuffer?
        guard CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleRange: CFRange(location: CFIndex(from), length: CFIndex(count)),
            sampleBufferOut: &slice) == noErr, let slice else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: CMTime(value: clock, timescale: CMTimeScale(rate)),
            decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: slice, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    private func silence(_ count: Int64) -> CMSampleBuffer? {
        let bytes = Int(count) * bytesPerFrame
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: bytes) == noErr else { return nil }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: CMItemCount(count),
            presentationTimeStamp: CMTime(value: clock, timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &buffer) == noErr else { return nil }
        clock += count
        return buffer
    }
}
