import Foundation
import AVFoundation

/// A single source media file shown in the Join list or selected for splitting.
struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var duration: CMTime = .zero
    var sizeBytes: Int64 = 0

    // Detailed media info (populated by load(from:)).
    var width: Int = 0
    var height: Int = 0
    var frameRate: Double = 0
    var videoCodec: String = ""
    var audioCodec: String = ""
    var audioBitrate: Double = 0   // bits per second

    var displayName: String { url.lastPathComponent }

    var durationString: String {
        guard duration.isValid, duration.seconds.isFinite else { return "—" }
        return MediaItem.format(seconds: duration.seconds)
    }

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var resolutionString: String { width > 0 && height > 0 ? "\(width) × \(height)" : "—" }

    var frameRateString: String {
        guard frameRate > 0 else { return "—" }
        // Trim trailing zeros: 30, 23.976, 59.94 …
        let s = String(format: "%.3f", frameRate)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        return "\(s) fps"
    }

    var videoCodecString: String { videoCodec.isEmpty ? "—" : videoCodec }
    var audioCodecString: String { audioCodec.isEmpty ? "—" : audioCodec }

    var audioBitrateString: String {
        guard audioBitrate > 0 else { return "—" }
        return "\(Int((audioBitrate / 1000).rounded())) kbps"
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Loads duration, file size, and detailed track info off the main actor.
    static func load(from url: URL) async -> MediaItem {
        var item = MediaItem(url: url)
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            item.duration = duration
        }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            item.sizeBytes = Int64(size)
        }

        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await video.load(.naturalSize),
               let transform = try? await video.load(.preferredTransform) {
                let resolved = size.applying(transform)
                item.width = Int(abs(resolved.width).rounded())
                item.height = Int(abs(resolved.height).rounded())
            }
            if let fps = try? await video.load(.nominalFrameRate) {
                item.frameRate = Double(fps)
            }
            if let descs = try? await video.load(.formatDescriptions), let desc = descs.first {
                item.videoCodec = codecName(CMFormatDescriptionGetMediaSubType(desc))
            }
        }

        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            if let descs = try? await audio.load(.formatDescriptions), let desc = descs.first {
                item.audioCodec = codecName(CMFormatDescriptionGetMediaSubType(desc))
            }
            if let rate = try? await audio.load(.estimatedDataRate), rate > 0 {
                item.audioBitrate = Double(rate)
            }
        }

        return item
    }

    /// Maps a CoreMedia FourCC subtype to a human-readable codec name.
    static func codecName(_ subtype: FourCharCode) -> String {
        let bytes = [UInt8((subtype >> 24) & 0xFF), UInt8((subtype >> 16) & 0xFF),
                     UInt8((subtype >> 8) & 0xFF), UInt8(subtype & 0xFF)]
        let raw = String(bytes: bytes, encoding: .macOSRoman) ?? ""
        switch raw {
        case "avc1", "avc3":                       return "H.264"
        case "hvc1", "hev1":                       return "HEVC"
        case "mp4v":                               return "MPEG-4"
        case "ap4h", "apch", "apcn", "apcs", "apco": return "ProRes"
        case "av01":                               return "AV1"
        case "vp09":                               return "VP9"
        case "aac ", "mp4a":                       return "AAC"
        case "ac-3":                               return "AC-3"
        case "ec-3":                               return "E-AC-3"
        case "mp3 ", ".mp3":                       return "MP3"
        case "lpcm", "sowt", "twos":               return "PCM"
        case "alac":                               return "ALAC"
        default:                                   return raw.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    /// Formats a number of seconds as H:MM:SS (or MM:SS under an hour).
    static func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
