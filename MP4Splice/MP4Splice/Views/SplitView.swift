import SwiftUI

struct SplitView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case equalParts = "Equal parts"
        case splitPoints = "Split points"
        var id: String { rawValue }
    }

    @State private var source: MediaItem?
    @State private var mode: Mode = .equalParts
    @State private var partCount = 2
    @State private var splitPointText = ""

    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var status = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split one MP4 into multiple files.")
                .font(.callout)
                .foregroundStyle(.secondary)

            sourceRow

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(source == nil)

            modeControls
                .disabled(source == nil)

            segmentPreview

            controls
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
        }
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
            if isWorking {
                ProgressView(value: progress) { Text(status).font(.caption) }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption)
            } else if !status.isEmpty {
                Label(status, systemImage: "checkmark.circle")
                    .foregroundStyle(.green).font(.caption)
            }

            HStack {
                Spacer()
                Button { Task { await runSplit() } } label: {
                    Label("Split…", systemImage: "scissors")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || segments.isEmpty || isWorking)
            }
        }
    }

    // MARK: - Actions

    private func pickSource() {
        guard let url = Panels.pickMovies(allowsMultiple: false).first else { return }
        Task { source = await MediaItem.load(from: url) }
    }

    private func runSplit() async {
        errorMessage = nil
        status = ""
        guard let source else { return }
        guard let dir = Panels.pickDirectory() else { return }

        let base = source.url.deletingPathExtension().lastPathComponent
        isWorking = true
        progress = 0
        status = "Splitting…"
        do {
            let outputs = try await VideoSplitter.split(
                url: source.url,
                segments: segments,
                outputDir: dir,
                baseName: base) { p in progress = p }
            status = "Wrote \(outputs.count) files to \(dir.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

#Preview {
    SplitView().padding()
}
