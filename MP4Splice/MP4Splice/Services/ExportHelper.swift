import Foundation
import AVFoundation

enum ExportHelper {
    /// Runs an export session to completion while reporting progress on the main actor.
    /// Uses polling because AVAssetExportSession.progress is KVO-light and simplest to observe this way.
    static func run(_ session: AVAssetExportSession,
                    progress: @escaping @MainActor (Double) -> Void) async throws {
        let pollTask = Task {
            while !Task.isCancelled {
                let value = Double(session.progress)
                await progress(value)
                if session.status == .completed || session.status == .failed || session.status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }

        await session.export()
        pollTask.cancel()
        await progress(1.0)

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw VideoError.cancelled
        case .failed:
            throw VideoError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        default:
            throw VideoError.exportFailed("unexpected status \(session.status.rawValue)")
        }
    }
}
