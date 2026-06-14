import SwiftUI

/// Encoding controls shown when the Re-encode toggle is on.
struct EncodeSettingsView: View {
    @Binding var settings: EncodeSettings
    @State private var showGuide = false

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
                    HStack(spacing: 4) {
                        Text("Video bitrate")
                        Button { showGuide = true } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Show recommended bitrate guide")
                        .popover(isPresented: $showGuide, arrowEdge: .trailing) {
                            BitrateGuideView()
                        }
                    }
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

/// Reference table of recommended bitrates by content type, frame rate, and codec.
struct BitrateGuideView: View {
    private struct GuideRow: Identifiable {
        let id = UUID()
        let content, fps, h264, hevc: String
    }

    private let rows: [GuideRow] = [
        .init(content: "2D animation, cartoons, clean anime", fps: "23.976–30", h264: "3–5", hevc: "1.8–3"),
        .init(content: "Clean digital TV, sitcoms, talk shows", fps: "23.976–30", h264: "4–6", hevc: "2.5–4"),
        .init(content: "Live-action television drama", fps: "23.976–30", h264: "5–7", hevc: "3–4.5"),
        .init(content: "Live-action movies", fps: "23.976–30", h264: "6–9", hevc: "3.5–5.5"),
        .init(content: "Grainy, dark, effects-heavy or fast action", fps: "23.976–30", h264: "8–12", hevc: "5–8"),
        .init(content: "Animation at 50/60 fps", fps: "50–60", h264: "5–8", hevc: "3–5"),
        .init(content: "Live action at 50/60 fps", fps: "50–60", h264: "8–12", hevc: "5–8"),
        .init(content: "Sports or very high motion", fps: "50–60", h264: "10–15", hevc: "6–10"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended bitrate guide")
                .font(.headline)
            Text("Values are for 1080p. HEVC uses roughly 2/3 the bitrate of H.264 for similar quality.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Content type").bold()
                    Text("Frame rate").bold()
                    Text("H.264").bold()
                    Text("HEVC").bold()
                }
                Divider().gridCellColumns(4)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.content)
                        Text("\(row.fps) fps").foregroundStyle(.secondary)
                        Text("\(row.h264) Mbps")
                        Text("\(row.hevc) Mbps")
                    }
                }
            }
            .font(.callout)
        }
        .padding()
        .frame(width: 560)
    }
}

#Preview {
    EncodeSettingsView(settings: .constant(EncodeSettings())).padding()
}
