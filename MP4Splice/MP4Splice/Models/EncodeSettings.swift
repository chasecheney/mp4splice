import AVFoundation

/// User-configurable options for the re-encode (AVAssetWriter) path.
struct EncodeSettings: Equatable {
    enum Codec: String, CaseIterable, Identifiable {
        case h264 = "H.264"
        case hevc = "HEVC"
        var id: String { rawValue }
        var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
    }

    enum Resolution: String, CaseIterable, Identifiable {
        case p480 = "480p"
        case p720 = "720p"
        case p1080 = "1080p"
        case k2 = "2K"
        case k4 = "4K"
        case k8 = "8K"
        var id: String { rawValue }

        /// Target output height in pixels (width derived from source aspect ratio).
        var targetHeight: Int {
            switch self {
            case .p480: return 480
            case .p720: return 720
            case .p1080: return 1080
            case .k2:   return 1440
            case .k4:   return 2160
            case .k8:   return 4320
            }
        }

        /// Recommended average video bitrate (Mbps) for this resolution.
        var suggestedBitrateMbps: Double {
            switch self {
            case .p480: return 2.5
            case .p720: return 5
            case .p1080: return 10
            case .k2:   return 16
            case .k4:   return 35
            case .k8:   return 80
            }
        }

        static func nearest(toHeight h: Int) -> Resolution {
            allCases.min { abs($0.targetHeight - h) < abs($1.targetHeight - h) } ?? .p1080
        }
    }

    enum FrameRate: String, CaseIterable, Identifiable {
        case ntsc  = "NTSC"
        case pal   = "PAL"
        case f24   = "24"
        case f2997 = "29.97"
        case f30   = "30"
        case f60   = "60"
        case f120  = "120"
        case f240  = "240"
        var id: String { rawValue }

        var fps: Double {
            switch self {
            case .ntsc:  return 30000.0 / 1001.0   // 29.97
            case .pal:   return 25
            case .f24:   return 24
            case .f2997: return 30000.0 / 1001.0   // 29.97
            case .f30:   return 30
            case .f60:   return 60
            case .f120:  return 120
            case .f240:  return 240
            }
        }

        var frameDuration: CMTime {
            switch self {
            case .ntsc:  return CMTime(value: 1001, timescale: 30000)
            case .pal:   return CMTime(value: 1, timescale: 25)
            case .f24:   return CMTime(value: 1, timescale: 24)
            case .f2997: return CMTime(value: 1001, timescale: 30000)
            case .f30:   return CMTime(value: 1, timescale: 30)
            case .f60:   return CMTime(value: 1, timescale: 60)
            case .f120:  return CMTime(value: 1, timescale: 120)
            case .f240:  return CMTime(value: 1, timescale: 240)
            }
        }

        static func nearest(toFps f: Double) -> FrameRate {
            allCases.min { abs($0.fps - f) < abs($1.fps - f) } ?? .f30
        }
    }

    var codec: Codec = .h264
    var resolution: Resolution = .p1080
    var frameRate: FrameRate = .f30
    var videoBitrateMbps: Double = 10
    var audioBitrateKbps: Int = 192
    var audioSampleRate: Int = 48_000

    static let audioBitrateOptions = [128, 192, 256, 320]
    static let sampleRateOptions = [44_100, 48_000]

    /// Seeds resolution/frame rate from a source file, and bitrate from that resolution.
    mutating func applyDefaults(from item: MediaItem) {
        if item.height > 0 { resolution = .nearest(toHeight: item.height) }
        if item.frameRate > 0 { frameRate = .nearest(toFps: item.frameRate) }
        videoBitrateMbps = resolution.suggestedBitrateMbps
    }
}
