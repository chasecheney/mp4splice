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

/// Remembers folders the user has allowed the sandboxed app to write into, as
/// security-scoped bookmarks. A grant covers every folder beneath it, so allowing a
/// parent (say, a whole drive or share) means the dialog never comes up again there.
enum FolderAccess {
    private static let key = "grantedFolderBookmarks"

    /// Write access to `folder`: from a remembered grant if one covers it, otherwise by
    /// asking once with a panel opened at that folder. Nil if the user cancels.
    @MainActor
    static func writableFolder(for folder: URL) -> URL? {
        if let granted = grantedAncestor(of: folder) { return granted }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.prompt = "Grant Access"
        panel.message = "Allow MP4Splice to save joined files into this folder. "
            + "Choose a parent folder instead to cover everything inside it."
        guard panel.runModal() == .OK, let chosen = panel.url,
              covers(chosen, folder) else { return nil }
        if let data = try? chosen.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            var all = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
            all.append(data)
            UserDefaults.standard.set(all, forKey: key)
        }
        _ = chosen.startAccessingSecurityScopedResource()
        return chosen
    }

    private static func grantedAncestor(of folder: URL) -> URL? {
        let all = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        for data in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  covers(url, folder) else { continue }
            // Access stays open for the app's lifetime; grants are few and long-lived.
            if url.startAccessingSecurityScopedResource() { return url }
        }
        return nil
    }

    private static func covers(_ ancestor: URL, _ folder: URL) -> Bool {
        let a = ancestor.standardizedFileURL.resolvingSymlinksInPath().path
        let f = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return f == a || f.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }
}
