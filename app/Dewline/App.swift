import AppKit

@main
@MainActor
enum DewlineApp {
    static func main() {
        // mermaid-rs-renderer copies a system font into XDG_CACHE_HOME, or into ~/.cache without it.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        setenv("XDG_CACHE_HOME", caches.appending(path: "dev.arkwerx.dewline").path, 1)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = MainMenu.build()
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchWindow: LaunchWindowController?

    // AppKit asks at launch when nothing opens or restores, and when the Dock icon is clicked with no windows.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        LaunchWindowController.showsWhenNothingIsOpen
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showWelcome(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                openFolder(at: url)
            } else {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
        }
    }

    /// Called when the last tab closes.
    func nothingIsOpen() {
        if LaunchWindowController.showsWhenNothingIsOpen { showWelcome(nil) }
    }

    func closeLaunchWindow() {
        launchWindow?.close()
        launchWindow = nil
    }

    @objc func showWelcome(_ sender: Any?) {
        if launchWindow == nil { launchWindow = LaunchWindowController() }
        launchWindow?.showWindow(nil)
    }

    @objc func newDocument(_ sender: Any?) {
        let document = MarkdownDocument()
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    @objc func quickOpen(_ sender: Any?) {
        QuickOpenPanel.show(commands: false)
    }

    @objc func showCommandPalette(_ sender: Any?) {
        QuickOpenPanel.show(commands: true)
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(at: url)
    }

    /// Opens a window on `url`'s tree, or brings its window forward.
    func openFolder(at url: URL) {
        let folder = Folder(url)
        Library.noteOpened(folder.url, folder: true)
        let open = NSApp.windows.first { ($0.windowController as? MainWindowController)?.folder?.url.path == folder.url.path }
        if let open {
            open.makeKeyAndOrderFront(nil)
        } else {
            MainWindowController(folder: folder).showWindow(nil)
        }
    }
}
