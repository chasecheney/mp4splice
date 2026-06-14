import SwiftUI

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
                    Text("Video bitrate")
                    HStack(spacing: 8) {
                        Slider(value: $settings.videoBitrateMbps, in: 1...50, step: 1)
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
        }
    }
}

#Preview {
    EncodeSettingsView(settings: .constant(EncodeSettings())).padding()
}
