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
    private let inboxService = InboxService()
    private let defaults = UserDefaults.standard
    /// The test host neither resumes nor saves a session.
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// The last session, until it reopens.
    private var session: Session?
    /// True while launching to open a file, which then draws before the last session reopens behind it. Folders,
    /// links and files of other types come to application(_:open:) before launch finishes. AppKit hands a Markdown
    /// file from Finder or open(1) to NSDocumentController just after, and a path on the command line too. The dewline
    /// command sets DEWLINE_OPENS_FILE and sends the file over the control socket once the app listens.
    private var opensFile = ProcessInfo.processInfo.environment["DEWLINE_OPENS_FILE"] != nil || AppDelegate.namesFile(CommandLine.arguments.dropFirst())
    private var launched = false
    /// Whether application(_:open:) was handed anything before launch finished.
    private var openedBeforeLaunch = false

    /// Whether `arguments` hold a path besides `-Key value` pairs, which are defaults.
    private nonisolated static func namesFile(_ arguments: ArraySlice<String>) -> Bool {
        var arguments = arguments
        while let argument = arguments.popFirst() {
            guard argument.hasPrefix("-") else { return true }
            arguments = arguments.dropFirst()
        }
        return false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isTestHost else { return }
        session = Session.load(from: defaults) ?? Session(windows: [])
    }

    /// Reopens the last session's windows, behind `front` when a file opened at launch, then prunes snapshots.
    private func resume(behind front: NSWindow? = nil) {
        opensFile = false
        guard let session else { return }
        self.session = nil
        MainWindowController.resume(session, behind: front)
        prune()
    }

    /// A document's window showed, which while launching to open a file is that file's.
    func documentDidShow(_ window: NSWindow?) {
        if opensFile { resume(after: window) }
    }

    /// Reopens the last session once `window`, the file asked for at launch, has drawn its first frame.
    private func resume(after window: NSWindow?) {
        guard session != nil else { return }
        guard let window, window.isVisible else { return resume() }
        window.afterDrawing { [weak self, weak window] in self?.resume(behind: window) }
    }

    /// Only the app prunes snapshots, once, with the last session's documents open again.
    private func prune() {
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
        launched = true
        // A launch to open something that application(_:open:) never saw is a Markdown file on its way.
        if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == false, !openedBeforeLaunch { opensFile = true }
        // Before AppKit decides whether to show the launch window, which it shows only when nothing reopened.
        if opensFile, session != nil {
            // A file that never shows (the dewline command gives up after 10 s) leaves the session to reopen then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, session != nil else { return }
                resume()
                if applicationShouldOpenUntitledFile(NSApp) { showWelcome(nil) }
            }
        } else {
            resume()
        }
        Updates.shared.start()
        NSApp.servicesProvider = inboxService
        // The test host leaves the real socket alone; ControlSocketTests make their own.
        guard !isTestHost else { return }
        Preferences.shared.keepWindows()
        Export.publishPreviewStylesheet()
        NotificationCenter.default.addObserver(forName: ThemeStore.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Export.publishPreviewStylesheet() }
        }
        if !UserDefaults.standard.bool(forKey: Welcome.shownKey) {
            UserDefaults.standard.set(true, forKey: Welcome.shownKey)
            // Opened before AppKit asks for an untitled file, so the guide shows in place of the launch window.
            replayDemo(nil)
        }
        let engine = MarkdownDocument.sharedEngine
        let control = ControlSocket(path: ControlSocket.standardPath, notify: { claim in
            Updates.shared.checkBundleOnDisk()
            if let engine { LiveFile.claim(claim, engine: engine) }
        }) { [weak self] request, connection in
            Updates.shared.checkBundleOnDisk()
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
                return resume(after: nil)
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
        jump(document, line: request.line, column: request.column)
        if request.wait { document.answerWhenClosed(connection) }
        connection.reply(.opened)
    }

    /// Opens `url` as Markdown, or brings its window forward, with the caret at `line` and `column`.
    @discardableResult
    func show(_ url: URL, line: Int?, column: Int?) throws -> MarkdownDocument {
        let document = try openMarkdown(at: url)
        jump(document, line: line, column: column)
        return document
    }

    private func jump(_ document: MarkdownDocument, line: Int?, column: Int?) {
        if let line {
            (document.windowControllers.first as? MainWindowController)?.textView?.jump(toLine: line, column: column ?? 1)
        }
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

    /// Help > Replay the Demo, and the first launch: a fresh Welcome.md, then Demo's edit to it.
    @objc func replayDemo(_ sender: Any?) {
        let url = Welcome.url
        NSDocumentController.shared.document(for: url)?.close()
        do {
            try Welcome.copy(to: url, fresh: true)
            WelcomeDemo.play(try openMarkdown(at: url), at: url)
        } catch {
            NSApp.presentError(error)
        }
    }

    // AppKit asks at launch when nothing opens or restores, and when the Dock icon is clicked with no windows.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !opensFile && LaunchWindowController.showsWhenNothingIsOpen && !NSApp.windows.contains { $0.windowController is MainWindowController && ($0.isVisible || $0.isMiniaturized) }
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showWelcome(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !launched { openedBeforeLaunch = true }
        for url in urls {
            if url.scheme == "dewline" {
                if url.host == "join" {
                    Collaboration.join(link: url.absoluteString)
                } else {
                    SchemeLinks.handle(url)
                }
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if !launched { opensFile = true }
                resume(after: openFolder(at: url))
            } else {
                if !launched { opensFile = true }
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                    guard let error else { return }
                    NSApp.presentError(error)
                    self?.resume(after: nil)
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
    @discardableResult
    func openFolder(at url: URL) -> NSWindow? {
        let folder = Folder(url)
        Library.noteOpened(folder.url, folder: true)
        let window = NSApp.windows.first { ($0.windowController as? MainWindowController)?.folder?.url.path == folder.url.path }
            ?? MainWindowController(folder: folder).window
        window?.windowController?.showWindow(nil)
        return window
    }
}
