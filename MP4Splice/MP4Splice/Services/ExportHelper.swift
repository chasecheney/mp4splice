import Foundation
import AVFoundation

/// Wraps a non-Sendable value so it can be referenced from `@Sendable` closures
/// (cancellation handlers). Used only where access is otherwise serialized.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum ExportHelper {
    /// Reports progress through AVFoundation's last step, which otherwise shows nothing.
    /// With fast start on, finishing a movie moves the written file aside as
    /// `<name>.sb-…` and rewrites it into `<name>` with the index at the front. On a network
    /// share that is a second full write (about a minute for 200 MB over a remote link), so
    /// it is watched: progress = bytes in `<name>` / size of the `.sb-` original. Nothing
    /// is written anywhere else. If the folder can't be listed (sandbox access to the file
    /// only), it stays a plain "Finishing file…".
    static func watchFinishing(_ output: URL,
                               progress: @escaping @MainActor (Double) -> Void) async -> Task<Void, Never> {
        let folder = output.deletingLastPathComponent()
        let where_ = (try? folder.resourceValues(forKeys: [.volumeIsLocalKey, .volumeNameKey]))
        let label = where_?.volumeIsLocal == false
            ? "Finishing file on \(where_?.volumeName ?? "the network volume")…" : "Finishing file…"
        await JobPhase.set(label, resetProgress: true)
        let prefix = output.lastPathComponent + ".sb-"
        return Task.detached {
            let fm = FileManager.default
            func size(_ path: String) -> Int {
                (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            }
            while !Task.isCancelled {
                let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                let total = names.filter { $0.hasPrefix(prefix) }
                    .map { size(folder.appendingPathComponent($0).path) }.max() ?? 0
                if total > 0 {
                    let done = size(output.path)
                    await progress(min(Double(done) / Double(total), 0.999))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Runs an export session to completion while reporting progress on the main actor.
    /// Responds to task cancellation by cancelling the export.
    static func run(_ session: AVAssetExportSession,
                    progress: @escaping @MainActor (Double) -> Void) async throws {
        let box = UncheckedSendableBox(session)

        let pollTask = Task {
            var finisher: Task<Void, Never>?
            defer { finisher?.cancel() }
            while !Task.isCancelled {
                let fraction = Double(box.value.progress)
                if finisher == nil { await progress(fraction) }   // the watcher owns the bar after
                if fraction >= 0.99, finisher == nil, let out = box.value.outputURL {
                    finisher = await watchFinishing(out, progress: progress)
                }
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
            throw VideoError.exportFailed(VideoError.detail(session.error, "unknown error"))
        default:
            throw VideoError.exportFailed("unexpected status \(session.status.rawValue)")
        }
    }
}
