import AppKit
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
    private let defaults = UserDefaults.standard
    /// The test host neither resumes nor saves a session.
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // Before AppKit decides whether to show the launch window, which it shows only when nothing reopened.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isTestHost, let session = Session.load(from: defaults) else { return }
        MainWindowController.resume(session)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updates.shared.start()
        // The test host leaves the real socket alone; ControlSocketTests make their own.
        guard !isTestHost else { return }
        Preferences.shared.keepWindows()
        if !UserDefaults.standard.bool(forKey: Welcome.shownKey) {
            UserDefaults.standard.set(true, forKey: Welcome.shownKey)
            // Opened before AppKit asks for an untitled file, so the guide shows in place of the launch window.
            showWelcomeGuide(nil)
        }
        let control = ControlSocket(path: ControlSocket.standardPath) { [weak self] request, connection in
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
        if !isTestHost { MainWindowController.session().save(to: defaults) }
    }

    /// Opens a file for the `dewline` command as Markdown, whatever its extension (git's COMMIT_EDITMSG has none),
    /// with the caret at the line and column asked for.
    func open(_ request: ControlSocket.Open, for connection: ControlSocket.Connection) {
        let document: MarkdownDocument
        do {
            document = try openMarkdown(at: URL(fileURLWithPath: request.path))
        } catch {
            connection.reply(.refused(.cannotOpen, message: error.localizedDescription))
            return
        }
        if let line = request.line {
            (document.windowControllers.first as? MainWindowController)?.textView?.jump(toLine: line, column: request.column ?? 1)
        }
        if request.wait { document.answerWhenClosed(connection) }
        connection.reply(.opened)
    }

    /// Opens the file at `url` as Markdown, whatever its extension, or brings its window forward.
    @discardableResult
    private func openMarkdown(at url: URL) throws -> MarkdownDocument {
        let controller = NSDocumentController.shared
        let document: MarkdownDocument
        if let open = controller.document(for: url) as? MarkdownDocument {
            document = open
        } else {
            document = try MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
            controller.addDocument(document)
            controller.noteNewRecentDocumentURL(url)
            document.makeWindowControllers()
        }
        document.showWindows()
        return document
    }

    /// Help > Welcome to Dewline: the reader's copy of the guide.
    @objc func showWelcomeGuide(_ sender: Any?) {
        do {
            try openMarkdown(at: Welcome.copy())
        } catch {
            NSApp.presentError(error)
        }
    }

    /// Help > Watch a Change Land: opens the guide, then writes a Demo note into it from outside, as an agent would.
    @objc func runWelcomeDemo(_ sender: Any?) {
        let url: URL
        do {
            url = try Welcome.copy()
            try openMarkdown(at: url)
        } catch {
            NSApp.presentError(error)
            return
        }
        // Long enough to see the page before the note arrives.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            do {
                try Welcome.writeDemo(to: url)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    // AppKit asks at launch when nothing opens or restores, and when the Dock icon is clicked with no windows.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        LaunchWindowController.showsWhenNothingIsOpen && !NSApp.windows.contains { $0.windowController is MainWindowController && ($0.isVisible || $0.isMiniaturized) }
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
