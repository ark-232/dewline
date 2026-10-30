import AppKit
import MdCore
import os

@main
@MainActor
enum DewlineApp {
    static func main() {
        // mermaid-rs-renderer copies a system font into XDG_CACHE_HOME, or into ~/.cache without it.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        setenv("XDG_CACHE_HOME", caches.appending(path: "dev.arkwerx.dewline").path, 1)
        FontLibrary.registerAtLaunch()
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
    private var control: ControlSocket?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(prune), name: NSApplication.didFinishRestoringWindowsNotification, object: nil)
    }

    /// Only the app prunes snapshots, once, with the last session's documents open again.
    @objc private func prune() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didFinishRestoringWindowsNotification, object: nil)
        guard let engine = MarkdownDocument.sharedEngine else { return }
        DispatchQueue.global(qos: .utility).async {
            do throws(ChangeEngine.Failure) {
                try engine.prune()
            } catch {
                Logger(subsystem: "dev.arkwerx.dewline", category: "engine")
                    .error("Snapshots were not pruned: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updates.shared.start()
        // The test host leaves the real socket alone; ControlSocketTests make their own.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let engine = MarkdownDocument.sharedEngine
        let control = ControlSocket(path: ControlSocket.standardPath, notify: { claim in
            if let engine { LiveFile.claim(claim, engine: engine) }
        }) { [weak self] request, connection in
            self?.open(request, for: connection)
        }
        do {
            try control.start()
            self.control = control
        } catch {
            Logger(subsystem: "dev.arkwerx.dewline", category: "control")
                .error("No control socket, so the dewline command can't reach this app: \(String(describing: error), privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
    }

    /// Opens a file for the `dewline` command as Markdown, whatever its extension (git's COMMIT_EDITMSG has none),
    /// with the caret at the line and column asked for.
    func open(_ request: ControlSocket.Open, for connection: ControlSocket.Connection) {
        let url = URL(fileURLWithPath: request.path)
        let controller = NSDocumentController.shared
        if let open = controller.document(for: url) as? MarkdownDocument {
            return show(open, for: request, connection)
        }
        Task {
            let document: MarkdownDocument
            do {
                document = try await MarkdownDocument.open(url)
            } catch {
                connection.reply(.refused(.cannotOpen, message: error.localizedDescription))
                return
            }
            // Another request may have opened it while this one read.
            if let open = controller.document(for: url) as? MarkdownDocument {
                document.close()
                return show(open, for: request, connection)
            }
            controller.addDocument(document)
            controller.noteNewRecentDocumentURL(url)
            document.makeWindowControllers()
            show(document, for: request, connection)
        }
    }

    private func show(_ document: MarkdownDocument, for request: ControlSocket.Open, _ connection: ControlSocket.Connection) {
        document.showWindows()
        if let line = request.line {
            (document.windowControllers.first as? MainWindowController)?.textView?.jump(toLine: line, column: request.column ?? 1)
        }
        if request.wait { document.answerWhenClosed(connection) }
        connection.reply(.opened)
    }

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
