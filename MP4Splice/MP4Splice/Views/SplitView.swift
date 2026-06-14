import SwiftUI

struct SplitView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case equalParts = "Equal parts"
        case splitPoints = "Split points"
        var id: String { rawValue }
    }

    @EnvironmentObject var queue: JobQueue

    @State private var source: MediaItem?
    @State private var mode: Mode = .equalParts
    @State private var partCount = 2
    @State private var splitPointText = ""
    @State private var reencode = false
    @State private var settings = EncodeSettings()

    @State private var status = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QueueIndicator()

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

            Toggle("Re-encode (slower, fixes mismatched formats)", isOn: $reencode)
                .font(.callout)
                .disabled(source == nil)
                .onChange(of: reencode) { on in
                    if on, let source { settings.applyDefaults(from: source) }
                }

            if reencode {
                EncodeSettingsView(settings: $settings)
            }

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
        Task { source = await MediaItem.load(from: url) }
    }

    private func enqueueSplit() {
        errorMessage = nil
        status = ""
        guard let source else { return }
        guard let dir = Panels.pickDirectory() else { return }

        let base = source.url.deletingPathExtension().lastPathComponent
        let sourceURL = source.url
        let segmentsSnapshot = segments
        let useReencode = reencode
        let settingsSnapshot = settings

        // Deterministic output names so they can be cleaned up on cancel.
        let outputURLs = (1...segmentsSnapshot.count).map {
            dir.appendingPathComponent(String(format: "%@-%02d.mp4", base, $0))
        }

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
