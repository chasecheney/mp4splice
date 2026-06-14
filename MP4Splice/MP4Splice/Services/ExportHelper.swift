import Foundation
import AVFoundation

/// Wraps a non-Sendable value so it can be referenced from `@Sendable` closures
/// (cancellation handlers). Used only where access is otherwise serialized.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum ExportHelper {
    /// Runs an export session to completion while reporting progress on the main actor.
    /// Responds to task cancellation by cancelling the export.
    static func run(_ session: AVAssetExportSession,
                    progress: @escaping @MainActor (Double) -> Void) async throws {
        let box = UncheckedSendableBox(session)

        let pollTask = Task {
            while !Task.isCancelled {
                await progress(Double(box.value.progress))
                let status = box.value.status
                if status == .completed || status == .failed || status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }

        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            box.value.cancelExport()
        }

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
