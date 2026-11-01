import AppKit
import Quartz
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

/// Finder-style Quick Look: the panel is shown without taking focus, so the list keeps
/// the keyboard (arrow keys move the selection natively) and the panel follows the
/// selection. SwiftUI's `.quickLookPreview` makes the panel the key window instead.
/// The panel finds its controller through the responder chain; `AppDelegate` answers.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []
    private var index = 0
    private weak var returnWindow: NSWindow?
    /// Moves the list selection by ±1. The panel takes key status when it opens (it does
    /// in Finder too), so ↑/↓ arrive here and are handed back to the list, as Finder does.
    var moveSelection: ((Int) -> Void)?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ urls: [URL], at index: Int) {
        self.urls = urls
        self.index = index
        let panel = QLPreviewPanel.shared()!
        // Also attach directly: SwiftUI wraps the app delegate, so AppDelegate may not be
        // where the panel looks for a controller in the responder chain.
        if panel.dataSource !== self { attach(panel) }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = index
        } else {
            if let key = NSApp.keyWindow, key !== panel { returnWindow = key }
            panel.becomesKeyOnlyIfNeeded = true
            panel.orderFront(nil)          // not makeKeyAndOrderFront
        }
    }

    func hide() {
        if isVisible { QLPreviewPanel.shared().orderOut(nil) }
        restoreFocus()
    }

    /// Back to the window the preview was opened from, so the list has the keyboard.
    private func restoreFocus() {
        returnWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown else { return false }
            switch event.keyCode {
            case 125: moveSelection?(1);  return true    // ↓
            case 126: moveSelection?(-1); return true    // ↑
            case 49, 53: hide();          return true    // Space, Escape
            default: return false
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { restoreFocus() }   // closed with its own button
    }

    func attach(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
    }

    func detach(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

/// Takes Quick Look panel control for the app (end of the responder chain).
final class AppDelegate: NSResponder, NSApplicationDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLook.shared.attach(panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLook.shared.detach(panel) }
    }
}
