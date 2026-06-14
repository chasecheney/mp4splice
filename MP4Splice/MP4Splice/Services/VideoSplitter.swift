import Foundation
import AVFoundation

/// A single output segment, defined by a half-open time range [start, end).
struct SplitSegment: Identifiable, Hashable {
    let id = UUID()
    var start: Double   // seconds
    var end: Double     // seconds

    var durationSeconds: Double { max(0, end - start) }
}

/// Splits a single media file into multiple MP4 segments using AVFoundation.
enum VideoSplitter {

    /// Builds equal-length segments covering the whole asset.
    static func equalSegments(totalSeconds: Double, count: Int) -> [SplitSegment] {
        guard count > 0, totalSeconds > 0 else { return [] }
        let step = totalSeconds / Double(count)
        return (0..<count).map { i in
            SplitSegment(start: Double(i) * step,
                         end: (i == count - 1) ? totalSeconds : Double(i + 1) * step)
        }
    }

    /// Builds segments from an ordered list of split points (in seconds).
    static func segments(fromSplitPoints points: [Double], totalSeconds: Double) -> [SplitSegment] {
        let bounds = ([0] + points.sorted() + [totalSeconds])
            .filter { $0 >= 0 && $0 <= totalSeconds }
        var result: [SplitSegment] = []
        for i in 0..<(bounds.count - 1) where bounds[i + 1] > bounds[i] {
            result.append(SplitSegment(start: bounds[i], end: bounds[i + 1]))
        }
        return result
    }

    /// Exports each segment to outputDir as "<baseName>-NN.mp4". Returns written file URLs.
    static func split(url: URL,
                      segments: [SplitSegment],
                      outputDir: URL,
                      baseName: String,
                      reencode: Bool = false,
                      progress: @escaping @MainActor (Double) -> Void) async throws -> [URL] {
        guard !segments.isEmpty else { throw VideoError.noInputs }

        let asset = AVURLAsset(url: url)
        let timescale: CMTimeScale = 600
        var outputs: [URL] = []

        for (index, segment) in segments.enumerated() {
            let preset = reencode ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw VideoError.exportSessionUnavailable
            }

            let fileName = String(format: "%@-%02d.mp4", baseName, index + 1)
            let outURL = outputDir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: outURL)

            session.outputURL = outURL
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: timescale),
                end: CMTime(seconds: segment.end, preferredTimescale: timescale))

            // Spread per-segment progress across the overall bar.
            try await ExportHelper.run(session) { p in
                let overall = (Double(index) + p) / Double(segments.count)
                progress(overall)
            }
            outputs.append(outURL)
        }

        await progress(1.0)
        return outputs
    }
}
