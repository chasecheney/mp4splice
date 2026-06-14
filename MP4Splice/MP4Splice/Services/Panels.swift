import AppKit
import UniformTypeIdentifiers

/// Thin wrappers around AppKit open/save panels for picking media files and outputs.
enum Panels {
    static let movieTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie]

    static func pickMovies(allowsMultiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = movieTypes
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveMovie(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
