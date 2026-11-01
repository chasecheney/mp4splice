import Foundation

/// Lets any step of a running job name what it is doing ("Encoding", "Finishing
/// file…") without threading a second callback through every signature. JobQueue binds
/// `report` for the job's task; child tasks inherit it.
enum JobPhase {
    @TaskLocal static var report: (@MainActor @Sendable (String?, Bool) -> Void)?

    /// `resetProgress` starts the bar (and the time-left estimate) over for the new phase.
    static func set(_ phase: String?, resetProgress: Bool = false) async {
        if let report { await report(phase, resetProgress) }
    }
}

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
    let outputs: [URL]        // files to delete if the job is cancelled/discarded
    let operation: Operation

    @Published var status: JobStatus = .pending
    @Published var progress: Double = 0
    @Published var phase: String?
    private var phaseStart = Date()
    private var phaseStartProgress = 0.0

    func setPhase(_ newPhase: String?, resetProgress: Bool) {
        phase = newPhase
        if resetProgress { progress = 0 }
        phaseStart = Date()
        phaseStartProgress = progress
    }

    /// "about 25 s left", from how fast the current phase has moved so far.
    var timeLeftText: String? {
        guard status == .running else { return nil }
        let done = progress - phaseStartProgress
        let elapsed = Date().timeIntervalSince(phaseStart)
        guard done > 0.03, elapsed > 2, progress < 1 else { return nil }
        let left = elapsed / done * (1 - progress)
        if left < 90 { return "about \(max(1, Int(left.rounded()))) s left" }
        return "about \(Int((left / 60).rounded())) min left"
    }
    @Published var error: String?

    init(name: String, kind: String, outputs: [URL], operation: @escaping Operation) {
        self.name = name
        self.kind = kind
        self.outputs = outputs
        self.operation = operation
    }

    var statusText: String {
        switch status {
        case .pending:   return "Queued"
        case .running:   return [phase ?? "Processing…", timeLeftText].compactMap { $0 }.joined(separator: " · ")
        case .completed: return "Done"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isFinished: Bool {
        status == .completed || status == .failed || status == .cancelled
    }
}
