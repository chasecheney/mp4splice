import Foundation
import AVFoundation

/// A single source media file shown in the Join list or selected for splitting.
struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var duration: CMTime = .zero
    var sizeBytes: Int64 = 0

    var displayName: String { url.lastPathComponent }

    var durationString: String {
        guard duration.isValid, duration.seconds.isFinite else { return "—" }
        return MediaItem.format(seconds: duration.seconds)
    }

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Loads duration and file size off the main actor.
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
        return item
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
