import SwiftUI

struct JoinView: View {
    @State private var items: [MediaItem] = []
    @State private var selection = Set<MediaItem.ID>()
    @State private var reencode = false

    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var status: String = ""
    @State private var errorMessage: String?

    private var totalDuration: String {
        let secs = items.reduce(0.0) { $0 + $1.duration.seconds }
        return MediaItem.format(seconds: secs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join multiple MP4 files into one. Files are combined top to bottom.")
                .font(.callout)
                .foregroundStyle(.secondary)

            fileTable

            HStack {
                Button { addFiles() } label: { Label("Add Files…", systemImage: "plus") }
                Button { removeSelected() } label: { Label("Remove", systemImage: "minus") }
                    .disabled(selection.isEmpty)
                Divider().frame(height: 16)
                Button { move(up: true) } label: { Image(systemName: "arrow.up") }
                    .disabled(selection.isEmpty)
                Button { move(up: false) } label: { Image(systemName: "arrow.down") }
                    .disabled(selection.isEmpty)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count) files · \(totalDuration)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Re-encode (slower, fixes mismatched formats)", isOn: $reencode)
                .font(.callout)

            controls
        }
    }

    private var fileTable: some View {
        Table(items, selection: $selection) {
            TableColumn("File") { Text($0.displayName) }
            TableColumn("Duration") { Text($0.durationString) }
                .width(80)
            TableColumn("Size") { Text($0.sizeString) }
                .width(90)
        }
        .frame(minHeight: 180)
        .overlay {
            if items.isEmpty {
                Text("No files added")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isWorking {
                ProgressView(value: progress) {
                    Text(status).font(.caption)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if !status.isEmpty {
                Label(status, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button {
                    Task { await runJoin() }
                } label: {
                    Label("Join…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(items.count < 2 || isWorking)
            }
        }
    }

    // MARK: - Actions

    private func addFiles() {
        let urls = Panels.pickMovies()
        guard !urls.isEmpty else { return }
        Task {
            for url in urls {
                let item = await MediaItem.load(from: url)
                items.append(item)
            }
        }
    }

    private func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private func move(up: Bool) {
        let indices = items.enumerated()
            .filter { selection.contains($0.element.id) }
            .map { $0.offset }
            .sorted(by: up ? (<) : (>))
        for i in indices {
            let target = up ? i - 1 : i + 1
            guard target >= 0, target < items.count else { continue }
            items.swapAt(i, target)
        }
    }

    private func runJoin() async {
        errorMessage = nil
        status = ""
        guard items.count >= 2 else { return }
        guard let output = Panels.saveMovie(defaultName: "joined.mp4") else { return }

        isWorking = true
        progress = 0
        status = "Joining…"
        do {
            try await VideoJoiner.join(
                urls: items.map(\.url),
                to: output,
                reencode: reencode) { p in progress = p }
            status = "Saved to \(output.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

#Preview {
    JoinView().padding()
}
