import SwiftUI
import UniformTypeIdentifiers

struct JoinView: View {
    @State private var items: [MediaItem] = []
    @State private var selection = Set<MediaItem.ID>()
    @State private var reencode = false
    @State private var settings = EncodeSettings()

    @State private var autoSort = true
    @State private var sortAscending = true
    @State private var isDropTargeted = false

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
                    .disabled(selection.isEmpty || autoSort)
                Button { move(up: false) } label: { Image(systemName: "arrow.down") }
                    .disabled(selection.isEmpty || autoSort)
                Divider().frame(height: 16)
                Menu {
                    Button("Name (A–Z)") { sortAscending = true; sortItems() }
                    Button("Name (Z–A)") { sortAscending = false; sortItems() }
                    Divider()
                    Toggle("Auto-sort on add", isOn: $autoSort)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .onChange(of: autoSort) { _ in if autoSort { sortItems() } }
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count) files · \(totalDuration)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            infoBox

            Toggle("Re-encode (slower, fixes mismatched formats)", isOn: $reencode)
                .font(.callout)
                .onChange(of: reencode) { on in
                    if on, let first = items.first { settings.applyDefaults(from: first) }
                }

            if reencode {
                EncodeSettingsView(settings: $settings)
            }

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
                Text("Drag video files here, or click Add Files")
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var selectedItem: MediaItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    @ViewBuilder
    private var infoBox: some View {
        if let item = selectedItem {
            GroupBox("File info — \(item.displayName)") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    infoRow("Resolution", item.resolutionString)
                    infoRow("Frame rate", item.frameRateString)
                    infoRow("Video codec", item.videoCodecString)
                    infoRow("Audio codec", item.audioCodecString)
                    infoRow("Audio bitrate", item.audioBitrateString)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
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
        Task { await addURLs(urls) }
    }

    /// Loads new files (skipping duplicates) and appends them, sorting if auto-sort is on.
    @MainActor
    private func addURLs(_ urls: [URL]) async {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = await MediaItem.load(from: url)
            items.append(item)
        }
        if autoSort { sortItems() }
    }

    /// Finder-style natural ordering: alphabetical, but digit runs compare numerically
    /// (so "clip2" sorts before "clip10").
    private func sortItems() {
        items.sort { a, b in
            let result = a.displayName.localizedStandardCompare(b.displayName)
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// Suggests an output filename: the shared name across inputs + " Joined", or the
    /// first file's name + " Joined" when the inputs don't share a meaningful prefix.
    private func suggestedJoinName() -> String {
        let names = items.map { $0.url.deletingPathExtension().lastPathComponent }
        guard let first = names.first else { return "Joined.mp4" }

        var stem = first
        if names.count > 1 {
            let cleaned = Self.trimTrailingJunk(Self.commonPrefix(of: names))
            if cleaned.count >= 3 { stem = cleaned }   // "similar enough"
        }
        return "\(stem) Joined.mp4"
    }

    /// Longest common leading substring across all names.
    private static func commonPrefix(of names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            prefix = String(zip(prefix, name).prefix { $0.0 == $0.1 }.map(\.0))
            if prefix.isEmpty { break }
        }
        return prefix
    }

    /// Drops trailing separators and digits so "Vacation_0" becomes "Vacation".
    private static func trimTrailingJunk(_ s: String) -> String {
        let junk: Set<Character> = Set(" -_.0123456789")
        var chars = Array(s)
        while let last = chars.last, junk.contains(last) { chars.removeLast() }
        return String(chars)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, Self.isMovie(url) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task { await addURLs(urls) }
        }
    }

    private static func isMovie(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .mpeg4Movie)
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
        guard let output = Panels.saveMovie(defaultName: suggestedJoinName()) else { return }

        isWorking = true
        progress = 0
        status = "Joining…"
        do {
            try await VideoJoiner.join(
                urls: items.map(\.url),
                to: output,
                reencode: reencode,
                settings: settings) { p in progress = p }
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
