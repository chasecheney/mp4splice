import SwiftUI

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
                        JobRow(job: job) { queue.remove(job) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

private struct JobRow: View {
    @ObservedObject var job: Job
    var onRemove: () -> Void

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
            } else if job.status != .completed {
                Button { onRemove() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from queue")
            }
        }
        .padding(.vertical, 2)
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

#Preview {
    QueueView().environmentObject(JobQueue()).padding()
}
