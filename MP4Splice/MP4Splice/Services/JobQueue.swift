import Foundation
import Combine

/// Shared, sequential job processor. Jobs run one at a time in the background so the
/// Join/Split panes stay interactive while work is in progress.
@MainActor
final class JobQueue: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    private var isRunning = false
    private var currentTask: Task<JobOutcome, Never>?
    private var currentJobID: Job.ID?
    // Forwards each job's own @Published changes (status/progress) up to this queue
    // so views observing the queue (indicator, tab badge) refresh live.
    private var observers: [Job.ID: AnyCancellable] = [:]

    private enum JobOutcome {
        case completed
        case cancelled
        case failed(String)
    }

    // MARK: - Derived state for indicators

    var runningJob: Job? { jobs.first { $0.status == .running } }
    var pendingCount: Int { jobs.filter { $0.status == .pending }.count }
    var activeCount: Int { jobs.filter { $0.status == .pending || $0.status == .running }.count }
    var isActive: Bool { activeCount > 0 }
    var hasFinished: Bool { jobs.contains { $0.isFinished } }

    // MARK: - Mutations

    func add(_ job: Job) {
        observers[job.id] = job.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        jobs.append(job)
        Task { await processNext() }
    }

    /// Output URLs already targeted by jobs in the queue.
    private var reservedOutputs: Set<URL> { Set(jobs.flatMap { $0.outputs }) }

    /// Returns a non-colliding output URL by appending " (n)" before the extension.
    /// Always avoids other queued jobs; `avoidingDisk` also avoids existing files.
    func uniqueOutputURL(_ desired: URL, avoidingDisk: Bool) -> URL {
        let reserved = reservedOutputs
        func taken(_ u: URL) -> Bool {
            reserved.contains(u) || (avoidingDisk && FileManager.default.fileExists(atPath: u.path))
        }
        guard taken(desired) else { return desired }
        let dir = desired.deletingLastPathComponent()
        let stem = desired.deletingPathExtension().lastPathComponent
        let ext = desired.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// Returns a base name and matching segment URLs that collide with neither existing
    /// files nor queued jobs, bumping the base with " (n)" until all slots are free.
    func uniqueSplitOutputs(directory: URL, baseName: String, count: Int) -> (baseName: String, urls: [URL]) {
        let reserved = reservedOutputs
        func urls(_ base: String) -> [URL] {
            (1...max(count, 1)).map {
                directory.appendingPathComponent(String(format: "%@-%02d.mp4", base, $0))
            }
        }
        func collides(_ base: String) -> Bool {
            urls(base).contains { reserved.contains($0) || FileManager.default.fileExists(atPath: $0.path) }
        }
        var base = baseName
        var n = 2
        while collides(base) {
            base = "\(baseName) (\(n))"
            n += 1
        }
        return (base, urls(base))
    }

    /// Cancels (if running) or removes a job, deleting its output files unless it
    /// completed successfully.
    func cancelOrRemove(_ job: Job) {
        switch job.status {
        case .running:
            currentTask?.cancel()           // outputs deleted once the task unwinds
            forget(job)
        case .pending, .failed, .cancelled:
            deleteOutputs(of: job)
            forget(job)
        case .completed:
            forget(job)                     // keep the finished file
        }
    }

    func clearFinished() {
        for job in jobs where job.isFinished { observers[job.id] = nil }
        jobs.removeAll { $0.isFinished }
    }

    private func forget(_ job: Job) {
        observers[job.id] = nil
        jobs.removeAll { $0.id == job.id }
    }

    // MARK: - Processing

    private func processNext() async {
        guard !isRunning else { return }
        guard let job = jobs.first(where: { $0.status == .pending }) else { return }

        isRunning = true
        job.status = .running
        job.progress = 0

        let task = Task { () -> JobOutcome in
            do {
                try await job.operation { progress in job.progress = progress }
                return .completed
            } catch is CancellationError {
                return .cancelled
            } catch let error as VideoError {
                if case .cancelled = error { return .cancelled }
                return .failed(error.localizedDescription)
            } catch {
                return Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
        currentTask = task
        currentJobID = job.id
        let outcome = await task.value
        currentTask = nil
        currentJobID = nil

        switch outcome {
        case .completed:
            job.progress = 1
            job.status = .completed
        case .cancelled:
            job.status = .cancelled
            deleteOutputs(of: job)
        case .failed(let message):
            job.error = message
            job.status = .failed
            deleteOutputs(of: job)
        }

        isRunning = false
        await processNext()
    }

    private func deleteOutputs(of job: Job) {
        for url in job.outputs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
