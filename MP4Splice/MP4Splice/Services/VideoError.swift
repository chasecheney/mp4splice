import Foundation

enum VideoError: LocalizedError {
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
