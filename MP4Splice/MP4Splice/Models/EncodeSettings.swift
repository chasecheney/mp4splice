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
        case ntsc = "NTSC (29.97)"
        case pal  = "PAL (25)"
        case f24  = "24"
        case f30  = "30"
        case f60  = "60"
        case f120 = "120"
        case f240 = "240"
        var id: String { rawValue }

        var fps: Double {
            switch self {
            case .ntsc: return 30000.0 / 1001.0   // 29.97
            case .pal:  return 25
            case .f24:  return 24
            case .f30:  return 30
            case .f60:  return 60
            case .f120: return 120
            case .f240: return 240
            }
        }

        var frameDuration: CMTime {
            switch self {
            case .ntsc: return CMTime(value: 1001, timescale: 30000)
            case .pal:  return CMTime(value: 1, timescale: 25)
            case .f24:  return CMTime(value: 1, timescale: 24)
            case .f30:  return CMTime(value: 1, timescale: 30)
            case .f60:  return CMTime(value: 1, timescale: 60)
            case .f120: return CMTime(value: 1, timescale: 120)
            case .f240: return CMTime(value: 1, timescale: 240)
            }
        }

        static func nearest(toFps f: Double) -> FrameRate {
            allCases.min { abs($0.fps - f) < abs($1.fps - f) } ?? .f30
        }
    }

    var codec: Codec = .h264
    var resolution: Resolution = .p1080
    var frameRate: FrameRate = .f30
    var fillFrame: Bool = false   // false = letterbox (fit), true = fill (crop)
    var videoBitrateMbps: Double = 10
    var audioBitrateKbps: Int = 192
    var audioSampleRate: Int = 48_000
    /// Exact output canvas. When set (Automatic mode) it overrides `resolution`, whose
    /// height presets would shrink portrait clips (1080×2220 at "1080p" is 525×1080).
    var canvas: CGSize? = nil

    static let audioBitrateOptions = [128, 192, 256, 320]
    static let sampleRateOptions = [44_100, 48_000]

    /// Recommended bitrate for the current resolution and codec.
    /// HEVC needs roughly 2/3 the bitrate of H.264 for similar quality.
    var suggestedVideoBitrateMbps: Double {
        let h264 = resolution.suggestedBitrateMbps
        return codec == .hevc ? (h264 * 2.0 / 3.0).rounded() : h264
    }

    /// Seeds resolution/frame rate from a source file, and bitrate from that resolution/codec.
    mutating func applyDefaults(from item: MediaItem) {
        if item.height > 0 { resolution = .nearest(toHeight: item.height) }
        if item.frameRate > 0 { frameRate = .nearest(toFps: item.frameRate) }
        videoBitrateMbps = suggestedVideoBitrateMbps
    }
}

// MARK: - Automatic mode

/// What Automatic mode will do with the current clips, and why.
struct AutoPlan {
    let reencode: Bool
    let settings: EncodeSettings
    let summary: String
}

extension EncodeSettings {
    /// Lossless join when every clip shares size, frame rate and codecs; otherwise an
    /// H.264 re-encode matched to the majority of the clips, so nothing needs choosing.
    /// `loopsCut` clips are playing one pass of a loop: cutting mid-stream needs a
    /// frame-exact re-encode even when every clip matches.
    static func automatic(for items: [MediaItem], loopsCut: Int = 0) -> AutoPlan {
        let loaded = items.filter { $0.width > 0 && $0.height > 0 }
        guard loaded.count >= 2 else {
            return AutoPlan(reencode: false, settings: EncodeSettings(),
                            summary: "Add two or more clips.")
        }

        struct Size: Hashable { let w: Int; let h: Int }
        func majority<T: Hashable>(_ key: (MediaItem) -> T) -> T {
            let counts = Dictionary(grouping: loaded.map(key), by: { $0 }).mapValues(\.count)
            // Ties go to the earliest clip in the list, so the result is stable.
            let best = counts.values.max() ?? 0
            return loaded.map(key).first { counts[$0] == best }!
        }
        let sizeKey: (MediaItem) -> Size = { Size(w: $0.width, h: $0.height) }
        let fpsKey: (MediaItem) -> Int = { Int(($0.frameRate * 100).rounded()) }
        let audioKey: (MediaItem) -> String = { $0.audioCodec.isEmpty ? "none" : $0.audioCodec }

        let size = majority(sizeKey), fps = majority(fpsKey)
        let vcodec = majority { $0.videoCodec }, acodec = majority(audioKey)

        var differs: [String] = []
        func check(_ label: String, _ off: Int) {
            if off > 0 { differs.append("\(label) (\(off) of \(loaded.count))") }
        }
        check("size", loaded.filter { sizeKey($0) != size }.count)
        check("frame rate", loaded.filter { fpsKey($0) != fps }.count)
        check("video codec", loaded.filter { $0.videoCodec != vcodec }.count)
        check("audio", loaded.filter { audioKey($0) != acodec }.count)

        if loopsCut > 0 {
            differs.append("\(loopsCut) looping clip\(loopsCut == 1 ? "" : "s") cut to one loop")
        }
        if differs.isEmpty {
            return AutoPlan(reencode: false, settings: EncodeSettings(),
                            summary: "All clips match — joining without re-encoding, no quality loss.")
        }

        var s = EncodeSettings()
        s.codec = .h264
        let w = size.w - size.w % 2, h = size.h - size.h % 2
        s.canvas = CGSize(width: w, height: h)
        s.resolution = .nearest(toHeight: h)
        s.frameRate = .nearest(toFps: Double(fps) / 100)
        s.fillFrame = false

        // Bitrate: a quarter above the busiest clip of the majority size, so the hardware
        // encoder (less efficient than the phone's) does not visibly soften it; never below
        // a 0.1 bits-per-pixel floor; within 4–80 Mb/s.
        let source = loaded.filter { sizeKey($0) == size }.map(\.videoBitrate).max() ?? 0
        let floorBps = Double(w * h) * s.frameRate.fps * 0.1
        let mbps = min(max(max(source * 1.25, floorBps) / 1_000_000, 4), 80)
        s.videoBitrateMbps = (mbps * 2).rounded() / 2
        s.audioBitrateKbps = 192
        s.audioSampleRate = 48_000

        let fpsText = s.frameRate.fps.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(s.frameRate.fps)) : String(format: "%.2f", s.frameRate.fps)
        let rateText = s.videoBitrateMbps.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(s.videoBitrateMbps)) : String(format: "%.1f", s.videoBitrateMbps)
        return AutoPlan(
            reencode: true, settings: s,
            summary: "Re-encoding (\(differs.joined(separator: ", "))) to "
                   + "H.264 · \(w)×\(h) · \(fpsText) fps · \(rateText) Mb/s.")
    }
}
