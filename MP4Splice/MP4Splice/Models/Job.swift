import Foundation

enum JobStatus {
    case pending, running, completed, failed, cancelled
}

/// A unit of work (a join or split) that runs on the shared JobQueue.
/// The actual work is captured in `operation`, which receives a progress callback.
@MainActor
final class Job: ObservableObject, Identifiable {
    typealias Operation = (@escaping @MainActor (Double) -> Void) async throws -> Void

    let id = UUID()
    let name: String
    let kind: String          // "Join" or "Split"
    let operation: Operation

    @Published var status: JobStatus = .pending
    @Published var progress: Double = 0
    @Published var error: String?

    init(name: String, kind: String, operation: @escaping Operation) {
        self.name = name
        self.kind = kind
        self.operation = operation
    }

    var statusText: String {
        switch status {
        case .pending:   return "Queued"
        case .running:   return "Processing…"
        case .completed: return "Done"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isFinished: Bool {
        status == .completed || status == .failed || status == .cancelled
    }
}
