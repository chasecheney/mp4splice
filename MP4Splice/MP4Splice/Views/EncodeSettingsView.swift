import SwiftUI

/// Encoding options and the recommendations pane, laid out side by side.
struct EncodeOptionsPane: View {
    @Binding var settings: EncodeSettings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EncodeSettingsView(settings: $settings)
            RecommendationsView(settings: $settings)
        }
    }
}

/// Encoding controls shown when the Re-encode toggle is on.
struct EncodeSettingsView: View {
    @Binding var settings: EncodeSettings

    var body: some View {
        GroupBox("Encoding options") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Codec")
                    Picker("", selection: $settings.codec) {
                        ForEach(EncodeSettings.Codec.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                GridRow {
                    Text("Resolution")
                    Picker("", selection: $settings.resolution) {
                        ForEach(EncodeSettings.Resolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                GridRow {
                    Text("Frame rate")
                    Picker("", selection: $settings.frameRate) {
                        ForEach(EncodeSettings.FrameRate.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                GridRow {
                    Text("Aspect")
                    Toggle("Fill frame (crop instead of letterbox)", isOn: $settings.fillFrame)
                }
                GridRow {
                    Text("Video bitrate")
                    HStack(spacing: 8) {
                        Slider(value: $settings.videoBitrateMbps, in: 1...150, step: 1)
                            .frame(width: 180)
                        Text("\(Int(settings.videoBitrateMbps)) Mbps")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Audio bitrate")
                    Picker("", selection: $settings.audioBitrateKbps) {
                        ForEach(EncodeSettings.audioBitrateOptions, id: \.self) {
                            Text("\($0) kbps").tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                GridRow {
                    Text("Sample rate")
                    Picker("", selection: $settings.audioSampleRate) {
                        ForEach(EncodeSettings.sampleRateOptions, id: \.self) {
                            Text("\($0) Hz").tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            .padding(6)
            // Changing resolution or codec resets bitrate to the recommended value.
            .onChange(of: settings.resolution) { _ in
                settings.videoBitrateMbps = settings.suggestedVideoBitrateMbps
            }
            .onChange(of: settings.codec) { _ in
                settings.videoBitrateMbps = settings.suggestedVideoBitrateMbps
            }
        }
    }
}

/// Live recommendations for the selected resolution, codec, and frame-rate bucket.
/// Tap a value to apply it to the bitrate slider.
struct RecommendationsView: View {
    @Binding var settings: EncodeSettings

    private var isHEVC: Bool { settings.codec == .hevc }
    private var highFrameRate: Bool { settings.frameRate.fps >= 48 }

    private var recs: [BitrateRecommendation] {
        BitrateRecommendation.matching(resolution: settings.resolution,
                                       isHEVC: isHEVC,
                                       highFrameRate: highFrameRate)
    }

    private var contentTypes: [String] {
        var seen: [String] = []
        for r in recs where !seen.contains(r.content) { seen.append(r.content) }
        return seen
    }

    var body: some View {
        GroupBox("Recommended bitrate (Mbps)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(settings.resolution.rawValue) · \(settings.codec.rawValue) · \(highFrameRate ? "50–60" : "24–30") fps")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if recs.isEmpty {
                    Text("No recommendations for this resolution.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Content").bold()
                            Text("Streaming").bold()
                            Text("Local").bold()
                        }
                        Divider().gridCellColumns(3)
                        ForEach(contentTypes, id: \.self) { content in
                            GridRow {
                                Text(content)
                                cell(rec(content, "Streaming / VOD"))
                                cell(rec(content, "Local library"))
                            }
                        }
                    }
                    .font(.callout)

                    Text("Tap a value to use it. Shown as recommended (low–high).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(6)
            .frame(width: 320)
        }
    }

    private func rec(_ content: String, _ useCase: String) -> BitrateRecommendation? {
        recs.first { $0.content == content && $0.useCase == useCase }
    }

    @ViewBuilder
    private func cell(_ r: BitrateRecommendation?) -> some View {
        if let r {
            Button {
                settings.videoBitrateMbps = r.recommended
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(fmt(r.recommended)).fontWeight(.medium)
                    Text("\(fmt(r.low))–\(fmt(r.high))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .help("Set bitrate to \(fmt(r.recommended)) Mbps")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

#Preview {
    EncodeOptionsPane(settings: .constant(EncodeSettings())).padding()
}
