import AVFoundation

/// User-configurable options for the re-encode (AVAssetWriter) path.
struct EncodeSettings: Equatable {
    enum Codec: String, CaseIterable, Identifiable {
        case h264 = "H.264"
        case hevc = "HEVC"
        var id: String { rawValue }
        var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
    }

    var codec: Codec = .h264
    var videoBitrateMbps: Double = 10        // average target bitrate
    var audioBitrateKbps: Int = 192
    var audioSampleRate: Int = 48_000

    static let audioBitrateOptions = [128, 192, 256, 320]
    static let sampleRateOptions = [44_100, 48_000]
}
