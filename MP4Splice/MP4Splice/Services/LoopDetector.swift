import Foundation
import AVFoundation

/// Finds clips that replay their own content: story-style exports (Snapchat, Instagram),
/// Boomerangs and GIF-to-video conversions pad a short loop out to a fixed length.
///
/// Every frame is decoded to a tiny greyscale thumbnail, then two things are measured:
///  - **period**: the frame offset at which the picture repeats pixel-for-pixel, i.e. the
///    loop's length. Each offset is scored by the mean difference between frame i and
///    frame i−offset; a loop scores far below the clip's median offset (measured on real
///    clips: loops 0.06–0.20 of median, non-loops 0.62–0.75, still footage included).
/// The clip keeps frames 0..<period: every picture once, nothing already seen. A clip saved
/// partway into its loop therefore shows the loop's restart mid-clip (no frame repeats,
/// but the order is rotated); finding the loop's true start from pixels is not reliable.
enum LoopDetector {

    struct Loop: Equatable {
        /// Ranges of the source to play, in order; together exactly one loop.
        let ranges: [CMTimeRange]
        let periodSeconds: Double
        let clipSeconds: Double
        var keptSeconds: Double { ranges.reduce(0) { $0 + $1.duration.seconds } }
    }

    private static let thumbW = 16, thumbH = 32
    private static let ratio = 0.35          // best / median offset score below this = loop
    private static let minLoopSeconds = 1.0  // shorter loops are not looked for
    private static let minTailSeconds = 0.5  // nor one repeating less than this at the end
    /// Story segments are at most 60 s. Longer files are not searched: the cost grows with
    /// the square of the length, and a compilation is not a loop.
    static let maxClipSeconds = 60.0
    /// Mean per-pixel difference (of 255) below which two thumbnails are the same picture.
    /// Measured: copies 0.1–0.2 (up to ~3 where re-compressed), new footage 3–8.
    private static let identical = 1.0

    static func detect(url: URL) async -> Loop? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite,
              duration.seconds > 0, duration.seconds <= maxClipSeconds,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fps = try? await track.load(.nominalFrameRate), fps > 0,
              let (frames, times) = try? thumbnails(asset: asset, track: track)
        else { return nil }
        return analyse(frames: frames, times: times, fps: Double(fps), duration: duration)
    }

    // MARK: - Decoding

    /// Every frame as a thumbW×thumbH luma thumbnail, with its presentation time.
    private static func thumbnails(asset: AVAsset, track: AVAssetTrack) throws -> ([[UInt8]], [CMTime]) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: thumbW,
            kCVPixelBufferHeightKey as String: thumbH,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.compositionFailed }
        reader.add(output)
        guard reader.startReading() else { throw VideoError.compositionFailed }

        var frames: [[UInt8]] = []
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { continue }
            let w = min(CVPixelBufferGetWidthOfPlane(pixels, 0), thumbW)
            let h = min(CVPixelBufferGetHeightOfPlane(pixels, 0), thumbH)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            let src = base.assumingMemoryBound(to: UInt8.self)
            var luma = [UInt8](repeating: 0, count: thumbW * thumbH)
            for y in 0..<h {
                for x in 0..<w { luma[y * thumbW + x] = src[y * stride + x] }
            }
            frames.append(luma)
            times.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        guard reader.status == .completed else { throw VideoError.compositionFailed }
        // The reader hands frames over in presentation order; sort defensively anyway.
        let order = times.indices.sorted { times[$0] < times[$1] }
        return (order.map { frames[$0] }, order.map { times[$0] })
    }

    // MARK: - Analysis

    /// Mean luma under 20 of 255: a black (or near-black) frame.
    private static func isBlack(_ f: [UInt8]) -> Bool {
        f.reduce(0) { $0 + Int($1) } < 20 * f.count
    }

    private static func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var s = 0
        for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return s
    }

    private static func analyse(frames all: [[UInt8]], times: [CMTime],
                                fps: Double, duration: CMTime) -> Loop? {
        // A trailing black frame (some exports end on one) would be compared as content.
        var count = all.count
        while count > 0, isBlack(all[count - 1]) { count -= 1 }
        let fr = Array(all.prefix(count))
        let total = fr.count
        let lo = Int(minLoopSeconds * fps), tail = Int(minTailSeconds * fps)
        guard total - tail > lo else { return nil }

        func score(_ lag: Int, step: Int) -> Double {
            var sum = 0, n = 0
            var i = lag
            while i < total { sum += diff(fr[i], fr[i - lag]); n += 1; i += step }
            return Double(sum) / Double(max(n, 1))
        }

        // Every other frame for the sweep: half the cost, same answer.
        let scores = (lo..<(total - tail)).map { (score($0, step: 2), $0) }
        let median = scores.map(\.0).sorted()[scores.count / 2]
        guard median > 0 else { return nil }        // a frozen picture matches everywhere
        let hits = scores.filter { $0.0 / median < ratio }
        guard let first = hits.map(\.1).min() else { return nil }

        // The first loop (not a later multiple), its best offset, re-scored on every frame.
        let rough = hits.filter { $0.1 - first <= Int(fps * 0.5) }.min { $0.0 < $1.0 }!.1
        let period = (max(lo, rough - 2)..<min(total - tail, rough + 3))
            .map { (score($0, step: 1), $0) }.min { $0.0 < $1.0 }!.1
        // Best offset at the search floor: a slope into the floor, not a dip. (A joined set
        // opening with a near-still clip scored a false 1.00 s "loop" this way.)
        guard period > lo + 2 else { return nil }

        // Keep everything up to where the *identical* frames begin, and drop only those.
        // The repeat need not start exactly one period in: one clip's second pass opened
        // with ~2 s of new footage that only resembled the first pass (aligned difference
        // 3–8 per pixel), and the pixel-identical copy (0.1–0.2) began 1.5 s later. So:
        // the cut is the earliest frame from which the rest of the clip is a copy of the
        // frames one period earlier (±1 frame, for 15→30 fps duplicated frames). No guess
        // about where a loop "really" starts: rotating to the biggest picture jump was tried
        // and broke on a clip whose hard cut inside the loop outweighed its smooth loop join.
        // Black frames at either end of what is kept are dropped too.
        func t(_ i: Int) -> CMTime { i < total ? times[i] : duration }
        let pixels = Double(thumbW * thumbH)
        let aligned = (period..<total).map { i in
            Double([-1, 0, 1].map { diff(fr[i], fr[max(0, i - period + $0)]) }.min()!) / pixels
        }
        var repeatStart = period
        for s in aligned.indices where aligned[s] < identical {
            let rest = aligned[s...].sorted()
            if rest[rest.count / 2] < identical { repeatStart = period + s; break }
        }
        var first0 = 0
        while first0 < repeatStart - 1, isBlack(fr[first0]) { first0 += 1 }
        var end = repeatStart
        while end > first0 + 1, isBlack(fr[end - 1]) { end -= 1 }

        // Clip saved partway into its loop: the kept part is [B … jump][A], where A runs
        // from a jump in picture/action to the start of the repeat, and A's last frame
        // flows straight into the repeated frames (it was recorded that way). When those
        // repeated frames are the clip's own opening (copying the first couple of
        // seconds), A is the loop's real beginning: play A, then everything before it.
        // (Seen on one clip: 12 s, a jump, ~2 s, then the beginning again.)
        // Otherwise the clip's order is kept. A pixel test of "A's end vs frame 0" is not
        // used: on that clip the opening differs slightly from what the repeat shows (18 vs an
        // ordinary 6), though it plays as continuous.
        let copiesFrom = repeatStart - period        // first frame the repeat copies
        if repeatStart < total, copiesFrom <= Int(fps * 2), end - copiesFrom > Int(fps) {
            // The boundary itself (last kept frame -> first copy) is a candidate too: when
            // it is the biggest jump, the clip was saved at the loop's start and is already
            // in order. Without it, a smooth loop got a random interior frame as its "seam".
            let last = end < total ? end + 1 : end
            let jumps = ((copiesFrom + 1)..<last).map { (diff(fr[$0], fr[$0 - 1]), $0) }
            if let seam = jumps.max(by: { $0.0 < $1.0 })?.1, seam > first0, seam < end {
                let ranges = [CMTimeRange(start: t(seam), end: t(end)),
                              CMTimeRange(start: t(first0), end: t(seam))]
                return Loop(ranges: ranges,
                            periodSeconds: t(period).seconds - t(0).seconds,
                            clipSeconds: duration.seconds)
            }
        }
        let ranges = [CMTimeRange(start: t(first0), end: t(end))]
        return Loop(ranges: ranges,
                    periodSeconds: t(period).seconds - t(0).seconds,
                    clipSeconds: duration.seconds)
    }
}
