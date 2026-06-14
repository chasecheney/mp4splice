import SwiftUI
import AppKit

struct QueueView: View {
    @EnvironmentObject var queue: JobQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Jobs run one at a time. You can keep adding jobs from the Join and Split tabs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.hasFinished)
            }

            if queue.jobs.isEmpty {
                Spacer()
                Text("No jobs in the queue")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(queue.jobs) { job in
                        JobRow(job: job) { queue.cancelOrRemove(job) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

private struct JobRow: View {
    @ObservedObject var job: Job
    var onCancelOrRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).fontWeight(.medium)
                Text("\(job.kind) · \(job.statusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if job.status == .running {
                    ProgressView(value: job.progress)
                        .frame(maxWidth: 280)
                }
                if job.status == .failed, let error = job.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if job.status == .running {
                Text("\(Int(job.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { onCancelOrRemove() } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Cancel job and delete its output")
            } else {
                if job.status == .completed {
                    Button { revealInFinder() } label: {
                        Image(systemName: "magnifyingglass.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                }
                Button { onCancelOrRemove() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(job.status == .completed ? "Remove from queue" : "Remove and delete output")
            }
        }
        .padding(.vertical, 2)
    }

    /// Selects the job's output file(s) in Finder.
    private func revealInFinder() {
        let urls = job.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// Compact banner shown on the Join/Split panes while jobs are active.
struct QueueIndicator: View {
    @EnvironmentObject var queue: JobQueue

    var body: some View {
        if queue.isActive {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if let running = queue.runningJob {
                    Text("Processing “\(running.name)” — \(Int(running.progress * 100))%")
                        .font(.caption)
                }
                if queue.pendingCount > 0 {
                    Text("· \(queue.pendingCount) waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

#Preview {
    QueueView().environmentObject(JobQueue()).padding()
}
