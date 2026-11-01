import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import QuickLookThumbnailing
import QuickLook

/// How the join is produced. Automatic decides per job from the clips themselves.
enum OutputMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case lossless = "Lossless only"
    case custom = "Custom re-encode"
    var id: String { rawValue }
}

/// The thumbnail Finder would show for a file (Quick Look's thumbnailer).
struct ClipThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 34, height: 56)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 68, height: 112),
                scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = rep.nsImage
            }
        }
    }
}

struct JoinView: View {
    @EnvironmentObject var queue: JobQueue

    @State private var items: [MediaItem] = []
    @State private var selection = Set<MediaItem.ID>()
    @State private var mode: OutputMode = .automatic
    /// Off by default; remembered once turned on.
    @AppStorage("removeRepeatedLoops") private var removeLoops = false
    @State private var settings = EncodeSettings()
    @State private var previewURL: URL?

    /// The list's order is shown, not hidden in a setting: "By name" sorts (and slots new
    /// clips in by name); any hand move switches to "Custom", which never re-sorts.
    @State private var orderByName = true
    @State private var sortAscending = true
    @State private var isDropTargeted = false

    @State private var status: String = ""
    @State private var errorMessage: String?

    private var totalDuration: String {
        let secs = items.reduce(0.0) { $0 + $1.duration.seconds }
        return MediaItem.format(seconds: secs)
    }

    var body: some View {
        VStack(spacing: 12) {
            QueueIndicator()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Join multiple MP4 files into one. Files are combined top to bottom.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Picker("Order", selection: $orderByName) {
                            Text("By name").tag(true)
                            Text("Custom").tag(false)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .onChange(of: orderByName) { byName in if byName { sortItems() } }
                        Button { reverseOrder() } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .help(orderByName ? "Reverse name order" : "Reverse the list")
                        .disabled(items.count < 2)
                        Spacer()
                    }

                    fileTable

            HStack {
                Button { addFiles() } label: { Label("Add Files…", systemImage: "plus") }
                Button { removeSelected() } label: { Label("Remove", systemImage: "minus") }
                    .disabled(selection.isEmpty)
                Button { previewSelected() } label: { Image(systemName: "eye") }
                    .help("Quick Look (Space)")
                    .disabled(selection.isEmpty)
                Divider().frame(height: 16)
                Button { move(up: true) } label: { Image(systemName: "arrow.up") }
                    .disabled(selection.isEmpty)
                    .help("Move up")
                Button { move(up: false) } label: { Image(systemName: "arrow.down") }
                    .disabled(selection.isEmpty)
                    .help("Move down")
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count) files · \(totalDuration)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            infoBox

            Picker("Output", selection: $mode) {
                ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .onChange(of: mode) { m in
                if m == .custom, let first = items.first { settings.applyDefaults(from: first) }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Remove repeated loops", isOn: $removeLoops)
                    .font(.callout)
                    .help("Drops frames that repeat earlier footage. If a clip was saved partway "
                          + "into its loop, the loop's start moves to the front.")
                Text("For clips that replay themselves, like story exports and Boomerangs. "
                     + "Keeps the footage once and re-encodes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)   // under the label, past the checkbox
            }
            if removeLoops, mode == .lossless, loopsCut > 0 {
                Label("Lossless only can't cut loops — they're kept whole.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                    switch mode {
                    case .automatic:
                        Label(EncodeSettings.automatic(for: items, loopsCut: loopsCut).summary,
                              systemImage: "wand.and.stars")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .lossless:
                        Label("Joins without re-encoding. Clips must share size, frame rate and codecs.",
                              systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .custom:
                        EncodeOptionsPane(settings: $settings)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider()

            controls
        }
    }

    private var fileTable: some View {
        Table(of: MediaItem.self, selection: $selection) {
            TableColumn("") { ClipThumbnail(url: $0.url) }
                .width(40)
            TableColumn("File") { fileCell($0) }
            TableColumn("Duration") { Text($0.durationString) }
                .width(80)
            TableColumn("Size") { Text($0.sizeString) }
                .width(90)
        } rows: {
            ForEach(items) { item in
                TableRow(item)
                    .draggable(item.id.uuidString)
                    .dropDestination(for: String.self) { ids in
                        moveRows(ids, onto: item.id)
                    }
            }
        }
        .contextMenu(forSelectionType: MediaItem.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                previewURL = item.url       // double-click previews
            }
        }
        // Space toggles the preview and Escape closes it, as in Finder. Keys stay with the
        // list while the panel shows, so without this Space just reopened it.
        .onKeyPress(.space) {
            if previewURL != nil { previewURL = nil; return .handled }
            guard !selection.isEmpty else { return .ignored }
            previewSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            guard previewURL != nil else { return .ignored }
            previewURL = nil
            return .handled
        }
        .quickLookPreview($previewURL, in: items.map(\.url))
        // Like Finder: while the preview is open, moving the selection changes what it
        // shows, and stepping through the preview moves the selection.
        .onChange(of: selection) { _ in
            if previewURL != nil,
               let url = items.first(where: { selection.contains($0.id) })?.url,
               url != previewURL {
                previewURL = url
            }
        }
        .onChange(of: previewURL) { url in
            if let url, let item = items.first(where: { $0.url == url }),
               !selection.contains(item.id) {
                selection = [item.id]
            }
        }
        .frame(height: 380)
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

    @ViewBuilder
    private func fileCell(_ item: MediaItem) -> some View {
        let issues = mismatchMessages(for: item)
        HStack(spacing: 4) {
            Text(item.displayName)
            if let loop = item.loop {
                Image(systemName: "repeat")
                    .foregroundStyle(removeLoops ? Color.accentColor : .secondary)
                    .help(String(format: "Repeats every %.1f s. %@ one loop: %.1f of %.1f s.",
                                 loop.periodSeconds, removeLoops ? "Keeping" : "Turn on Remove repeated loops to keep",
                                 loop.keptSeconds, loop.clipSeconds))
            } else if !item.loopChecked, removeLoops {
                ProgressView().controlSize(.mini).help("Checking for loops…")
            }
            if !issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Differs from the other files — " + issues.joined(separator: ", "))
            }
        }
    }

    private var selectedItem: MediaItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: - Mismatch detection

    /// Returns labels describing how `item` deviates from the majority of the list
    /// (resolution, frame rate, video/audio codec). Empty when it matches or info isn't loaded.
    private func mismatchMessages(for item: MediaItem) -> [String] {
        guard items.count > 1 else { return [] }
        var messages: [String] = []

        let resKey: (MediaItem) -> String = { "\($0.width)×\($0.height)" }
        if item.width > 0, distinctCount(resKey) > 1,
           let common = majority(resKey), resKey(item) != common {
            messages.append("Resolution \(item.resolutionString)")
        }

        let fpsKey: (MediaItem) -> Int = { Int(($0.frameRate * 100).rounded()) }
        if item.frameRate > 0, distinctCount(fpsKey) > 1,
           let common = majority(fpsKey), fpsKey(item) != common {
            messages.append("Frame rate \(item.frameRateString)")
        }

        if !item.videoCodec.isEmpty, distinctCount({ $0.videoCodec }) > 1,
           let common = majority({ $0.videoCodec }), item.videoCodec != common {
            messages.append("Video codec \(item.videoCodecString)")
        }

        let audioKey: (MediaItem) -> String = { $0.audioCodec.isEmpty ? "none" : $0.audioCodec }
        if distinctCount(audioKey) > 1,
           let common = majority(audioKey), audioKey(item) != common {
            messages.append("Audio codec \(item.audioCodecString)")
        }

        return messages
    }

    /// Most common value of `key` across the loaded items.
    private func majority<T: Hashable>(_ key: (MediaItem) -> T) -> T? {
        let counts = Dictionary(grouping: items.map(key), by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    private func distinctCount<T: Hashable>(_ key: (MediaItem) -> T) -> Int {
        Set(items.map(key)).count
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

                let issues = mismatchMessages(for: item)
                if !issues.isEmpty {
                    Label("Differs from other files: \(issues.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
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
            if let errorMessage {
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
                Button("Save As…") { enqueueJoin(askWhere: true) }
                    .disabled(items.count < 2)
                    .help("Choose where the joined file goes")
                Button {
                    enqueueJoin(askWhere: false)
                } label: {
                    Label("Add to Queue", systemImage: "plus.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(items.count < 2)
                .help("Saves next to the first clip")
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
            let id = item.id
            Task {   // ~0.5–1 s per clip; the list stays usable meanwhile
                // Files usually arrive by drag from Finder, so this app is in the
                // background: without an activity App Nap held the results back until
                // the window was clicked.
                let activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiated, reason: "Checking clips for loops")
                defer { ProcessInfo.processInfo.endActivity(activity) }
                let loop = await LoopDetector.detect(url: url)
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].loop = loop
                    items[i].loopChecked = true
                }
            }
        }
        if orderByName { sortItems() }
    }

    /// Clips that will play one pass of their loop instead of the whole clip.
    private var loopsCut: Int {
        removeLoops ? items.filter { $0.loop != nil }.count : 0
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

    /// Drag-to-reorder: dropped rows land where the target row is (before it when moving
    /// up the list, after it when moving down), keeping their own relative order.
    private func moveRows(_ idStrings: [String], onto target: MediaItem.ID) {
        let ids = Set(idStrings.compactMap(UUID.init(uuidString:)))
        guard !ids.isEmpty, !ids.contains(target),
              let from = items.firstIndex(where: { ids.contains($0.id) }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        let moving = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        guard let anchor = items.firstIndex(where: { $0.id == target }) else { return }
        items.insert(contentsOf: moving, at: from < to ? anchor + 1 : anchor)
        orderByName = false         // a hand-made order must not be re-sorted
    }

    /// Quick Look the first selected clip (in list order); arrow keys in the panel step
    /// through the rest of the list.
    private func previewSelected() {
        previewURL = items.first { selection.contains($0.id) }?.url
    }

    private func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    /// Name order: flip A–Z / Z–A (stays "By name"). Custom: reverse the list as it is.
    private func reverseOrder() {
        if orderByName {
            sortAscending.toggle()
            sortItems()
        } else {
            items.reverse()
        }
    }

    private func move(up: Bool) {
        orderByName = false
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

    /// Snapshots the current inputs and settings into a queued job, then leaves the
    /// pane ready for the next set of files.
    private func enqueueJoin(askWhere: Bool) {
        errorMessage = nil
        status = ""
        guard items.count >= 2, let firstURL = items.first?.url else { return }
        let output: URL
        let sourceFolder = firstURL.deletingLastPathComponent()
        if !askWhere, let folder = FolderAccess.writableFolder(for: sourceFolder) {
            _ = folder   // access is held open; the file goes in the clips' own folder
            // Never overwrite: bump the name past files on disk and queued jobs.
            output = queue.uniqueOutputURL(
                sourceFolder.appendingPathComponent(suggestedJoinName()), avoidingDisk: true)
        } else {
            guard let chosen = Panels.saveMovie(defaultName: suggestedJoinName()) else { return }
            // Don't clobber another queued job's output (disk collisions are handled by the save panel).
            output = queue.uniqueOutputURL(chosen, avoidingDisk: false)
        }

        let urls = items.map(\.url)
        let useReencode: Bool
        let settingsSnapshot: EncodeSettings
        switch mode {
        case .automatic:
            let plan = EncodeSettings.automatic(for: items, loopsCut: loopsCut)
            useReencode = plan.reencode
            settingsSnapshot = plan.settings
        case .lossless:
            useReencode = false
            settingsSnapshot = settings
        case .custom:
            useReencode = true
            settingsSnapshot = settings
        }
        // Loops are cut only when re-encoding: a stream copy can't cut on an exact frame.
        let ranges: [[CMTimeRange]?] = items.map {
            removeLoops && useReencode ? $0.loop?.ranges : nil
        }

        let job = Job(name: output.lastPathComponent, kind: "Join", outputs: [output]) { progress in
            try await VideoJoiner.join(
                urls: urls,
                to: output,
                reencode: useReencode,
                settings: settingsSnapshot,
                ranges: ranges,
                progress: progress)
        }
        queue.add(job)
        status = "Added “\(output.lastPathComponent)” to the queue"
    }
}

#Preview {
    JoinView().environmentObject(JobQueue()).padding()
}
