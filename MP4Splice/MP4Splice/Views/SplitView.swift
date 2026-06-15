import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct SplitView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case equalParts = "Equal parts"
        case splitPoints = "Split points"
        case extract = "Extract range"
        var id: String { rawValue }
    }

    @EnvironmentObject var queue: JobQueue

    @State private var source: MediaItem?
    @State private var player: AVPlayer?
    @State private var isDropTargeted = false
    @State private var mode: Mode = .equalParts
    @State private var partCount = 2
    @State private var splitPointText = ""
    @State private var startTC = ""
    @State private var endTC = ""
    @State private var reencode = false
    @State private var settings = EncodeSettings()

    @State private var status = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            QueueIndicator()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Split one video into multiple files. Drag a file in, or use Choose File.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    playerArea

                    sourceRow

                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(source == nil)

                    modeControls
                        .disabled(source == nil)

                    segmentPreview

                    Toggle("Re-encode (slower, fixes mismatched formats)", isOn: $reencode)
                        .font(.callout)
                        .disabled(source == nil)
                        .onChange(of: reencode) { on in
                            if on, let source { settings.applyDefaults(from: source) }
                        }

                    if reencode {
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

    private var playerArea: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
                VStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                    Text("Drag a video here to preview")
                }
                .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 260)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var sourceRow: some View {
        HStack {
            Button { pickSource() } label: { Label("Choose File…", systemImage: "film") }
            if let source {
                Text(source.displayName).fontWeight(.medium)
                Text("·").foregroundStyle(.secondary)
                Text(source.durationString).foregroundStyle(.secondary)
            } else {
                Text("No file selected").foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var modeControls: some View {
        switch mode {
        case .equalParts:
            Stepper(value: $partCount, in: 2...50) {
                Text("Split into \(partCount) equal parts")
            }
            .frame(maxWidth: 280)
        case .splitPoints:
            VStack(alignment: .leading, spacing: 4) {
                Text("Split points in seconds, comma-separated (e.g. 30, 90, 150)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("30, 90, 150", text: $splitPointText)
                    .textFieldStyle(.roundedBorder)
            }
        case .extract:
            VStack(alignment: .leading, spacing: 6) {
                Text("Extract a single clip. Enter times as H:MM:SS, MM:SS, or seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                timecodeRow(label: "Start", text: $startTC, placeholder: "0:00")
                timecodeRow(label: "End", text: $endTC, placeholder: "0:10")
            }
        }
    }

    private func timecodeRow(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 42, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            Button("Use playhead") { text.wrappedValue = currentPlayheadTimecode() }
                .disabled(player == nil)
        }
    }

    private var segments: [SplitSegment] {
        guard let source else { return [] }
        let total = source.duration.seconds
        switch mode {
        case .equalParts:
            return VideoSplitter.equalSegments(totalSeconds: total, count: partCount)
        case .splitPoints:
            let points = splitPointText
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return VideoSplitter.segments(fromSplitPoints: points, totalSeconds: total)
        case .extract:
            guard let start = Self.parseTimecode(startTC),
                  let rawEnd = Self.parseTimecode(endTC),
                  start >= 0, rawEnd > start else { return [] }
            let end = total > 0 ? min(rawEnd, total) : rawEnd
            guard end > start else { return [] }
            return [SplitSegment(start: start, end: end)]
        }
    }

    /// Parses "H:MM:SS", "MM:SS", or plain (decimal) seconds into seconds.
    static func parseTimecode(_ string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var total = 0.0
        for part in trimmed.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private func currentPlayheadTimecode() -> String {
        guard let player else { return "" }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let whole = Int(seconds)
        let cc = min(99, Int((seconds - Double(whole)) * 100))
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        return h > 0
            ? String(format: "%d:%02d:%02d.%02d", h, m, s, cc)
            : String(format: "%d:%02d.%02d", m, s, cc)
    }

    @ViewBuilder
    private var segmentPreview: some View {
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(segments.count) output files:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    Text(String(format: "%02d.  %@ – %@  (%@)",
                                idx + 1,
                                MediaItem.format(seconds: seg.start),
                                MediaItem.format(seconds: seg.end),
                                MediaItem.format(seconds: seg.durationSeconds)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption)
            } else if !status.isEmpty {
                Label(status, systemImage: "checkmark.circle")
                    .foregroundStyle(.green).font(.caption)
            }

            HStack {
                Spacer()
                Button { enqueueSplit() } label: {
                    Label("Add to Queue", systemImage: "plus.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || segments.isEmpty)
            }
        }
    }

    // MARK: - Actions

    private func pickSource() {
        guard let url = Panels.pickMovies(allowsMultiple: false).first else { return }
        load(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, Self.isMovie(url) else { return }
            Task { @MainActor in load(url) }
        }
    }

    private static func isMovie(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    /// Loads a source file, building the preview player and metadata.
    private func load(_ url: URL) {
        player = AVPlayer(url: url)
        status = ""
        errorMessage = nil
        Task { source = await MediaItem.load(from: url) }
    }

    private func enqueueSplit() {
        errorMessage = nil
        status = ""
        guard let source else { return }
        guard let dir = Panels.pickDirectory() else { return }

        let sourceBase = source.url.deletingPathExtension().lastPathComponent
        let sourceURL = source.url
        let segmentsSnapshot = segments
        let useReencode = reencode
        let settingsSnapshot = settings

        // Pick a base name whose segment files collide with neither disk nor queued jobs.
        let (base, outputURLs) = queue.uniqueSplitOutputs(
            directory: dir, baseName: sourceBase, count: segmentsSnapshot.count)

        let job = Job(name: "\(base) (\(segmentsSnapshot.count) parts)", kind: "Split", outputs: outputURLs) { progress in
            _ = try await VideoSplitter.split(
                url: sourceURL,
                segments: segmentsSnapshot,
                outputDir: dir,
                baseName: base,
                reencode: useReencode,
                settings: settingsSnapshot,
                progress: progress)
        }
        queue.add(job)
        status = "Added “\(base)” to the queue"
    }
}

#Preview {
    SplitView().environmentObject(JobQueue()).padding()
}
