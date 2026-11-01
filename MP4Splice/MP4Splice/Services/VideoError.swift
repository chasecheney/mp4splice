import Foundation

enum VideoError: LocalizedError {
    /// AVFoundation's description alone is often just "The operation could not be
    /// completed"; the domain/code chain (e.g. OSStatus -17913) is what pins it down.
    static func detail(_ error: Error?, _ fallback: String) -> String {
        guard let error else { return fallback }
        var parts: [String] = []
        var current: NSError? = error as NSError
        while let e = current, parts.count < 4 {
            let reason = e.localizedFailureReason.map { " – \($0)" } ?? ""
            parts.append("\(e.localizedDescription)\(reason) [\(e.domain) \(e.code)]")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " ← ")
    }

    case noInputs
    case unreadableAsset(URL)
    case noVideoTrack(URL)
    case compositionFailed
    case exportSessionUnavailable
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noInputs:
            return "No input files were provided."
        case .unreadableAsset(let url):
            return "Could not read \(url.lastPathComponent)."
        case .noVideoTrack(let url):
            return "\(url.lastPathComponent) has no usable video track."
        case .compositionFailed:
            return "Failed to build the composition from the source files."
        case .exportSessionUnavailable:
            return "Could not create an export session. The source formats may be incompatible."
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .cancelled:
            return "Operation was cancelled."
        }
    }
}
