import Foundation

/// Shared, sequential job processor. Jobs run one at a time in the background so the
/// Join/Split panes stay interactive while work is in progress.
@MainActor
final class JobQueue: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    private var isRunning = false

    var hasFinished: Bool { jobs.contains { $0.isFinished } }
    var activeCount: Int { jobs.filter { $0.status == .pending || $0.status == .running }.count }

    func add(_ job: Job) {
        jobs.append(job)
        Task { await processNext() }
    }

    /// Removes a job that isn't currently running.
    func remove(_ job: Job) {
        guard job.status != .running else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    private func processNext() async {
        guard !isRunning else { return }
        guard let job = jobs.first(where: { $0.status == .pending }) else { return }

        isRunning = true
        job.status = .running
        job.progress = 0
        do {
            try await job.operation { progress in job.progress = progress }
            job.progress = 1
            job.status = .completed
        } catch {
            job.error = error.localizedDescription
            job.status = .failed
        }
        isRunning = false

        await processNext()
    }
}
