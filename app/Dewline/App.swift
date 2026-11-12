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

/// What a launch shows when no file asked to open.
@MainActor
enum Launch {
    /// The launch window shows when nothing else opened and either the setting asks for it or there is no last
    /// session to reopen. The one caller keeps the test host windowless.
    static func shouldShowLaunchWindow(session: Session?, defaults: UserDefaults, openWindows: Int) -> Bool {
        guard openWindows == 0 else { return false }
        return Preferences(defaults: defaults).launchBehavior == .launchWindow || (session?.windows.isEmpty ?? true)
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
        RightPane.makeChanges = { ReviewViewController(for: $0) }
        RightPane.makeAgent = { AgentPanel.makeViewController(window: $0) }
        Review.closedNotes = {
            ClosedChanges.all.map { ClosedNote(url: $0.url, origin: $0.origin, time: $0.time) }.sorted { $0.time > $1.time }
        }
        FlowStatus.start()
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
        } else if !isTestHost, Launch.shouldShowLaunchWindow(session: session, defaults: defaults, openWindows: mainWindows) {
            // AppKit asks for the launch window next, in applicationShouldOpenUntitledFile.
            session = nil
        } else {
            resume()
        }
        Updates.shared.start()
        NSApp.servicesProvider = inboxService
        // The test host leaves the real socket alone; ControlSocketTests make their own.
        guard !isTestHost else { return }
        Preferences.shared.keepWindows()
        if let failure = MarkdownDocument.engineFailure { Tracking.report(.noEngine(failure)) }
        Capture.shared.register(Preferences.shared.captureShortcut)
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Capture.shared.register(Preferences.shared.captureShortcut) }
        }
        Export.publishPreviewStylesheet()
        NotificationCenter.default.addObserver(forName: ThemeStore.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Export.publishPreviewStylesheet() }
        }
        if !defaults.bool(forKey: Welcome.shownKey) {
            defaults.set(true, forKey: Welcome.shownKey)
            // Opened before AppKit asks for an untitled file, so the notes folder shows in place of the launch window.
            firstLaunch(in: FileActions.notesFolder)
        } else if DailyNote.opensAtLaunch(defaults: defaults) {
            openTodaysNote(nil)
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
            Tracking.report(.noSocket(error.localizedDescription))
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

    /// The first launch: Welcome.md in the notes folder, open in a window on that folder with the caret at its end.
    func firstLaunch(in folder: URL) {
        do {
            try Welcome.write(in: folder)
            Library.noteOpened(folder, folder: true)
            Self.welcomeWindow(in: folder).showWindow(nil)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// A window on `folder` with its Welcome.md open and the caret at the end, not yet shown.
    static func welcomeWindow(in folder: URL) -> MainWindowController {
        let controller = MainWindowController(folder: Folder(folder))
        controller.open(Welcome.url(in: folder), newTab: false)
        if let textView = controller.textView {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return controller
    }

    /// Help > Replay the Demo: Welcome.md again if it is gone, then Demo's change to it.
    @objc func replayDemo(_ sender: Any?) {
        let folder = FileActions.notesFolder
        do {
            try Welcome.write(in: folder)
            playDemo(at: Welcome.url(in: folder))
        } catch {
            NSApp.presentError(error)
        }
    }

    /// `dewline://demo`, the link in Welcome.md: Demo extends the paragraph that holds it.
    func playDemo(at url: URL) {
        do {
            WelcomeDemo.play(try openMarkdown(at: url), at: url)
        } catch {
            NSApp.presentError(error)
        }
    }

    // AppKit asks at launch when nothing opens or restores, and when the Dock icon is clicked with no windows.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !isTestHost && !opensFile && mainWindows == 0
    }

    /// Main windows on screen or in the Dock.
    private var mainWindows: Int {
        NSApp.windows.count { $0.windowController is MainWindowController && ($0.isVisible || $0.isMiniaturized) }
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
        if !isTestHost, Launch.shouldShowLaunchWindow(session: nil, defaults: defaults, openWindows: mainWindows) { showWelcome(nil) }
    }

    func closeLaunchWindow() {
        launchWindow?.close()
        launchWindow = nil
    }

    @objc func showWelcome(_ sender: Any?) {
        if launchWindow == nil { launchWindow = LaunchWindowController() }
        launchWindow?.showWindow(nil)
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

    // MARK: Notes and folders

    /// The tab in front, if it is a main window's.
    private var front: MainWindowController? {
        (NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.windowController is MainWindowController })?.windowController
            as? MainWindowController
    }

    /// The front window's folder, else the one Settings > General names for new notes.
    private var frontFolder: URL {
        front?.folder?.url ?? Preferences.shared.newFileFolder
    }

    /// File > New Note: "Untitled.md" in `frontFolder`, open with the caret ready.
    /// Its first line names it once it saves.
    @objc func newNote(_ sender: Any?) {
        do {
            let url = try FileActions.newNote(in: frontFolder)
            let controller = front?.folder != nil ? front : openFolder(at: Preferences.shared.newFileFolder)?.windowController as? MainWindowController
            guard let controller else { return }
            controller.open(url, newTab: true)
            if let document = NSDocumentController.shared.document(for: url) as? MarkdownDocument {
                FileActions.nameFromFirstLine(document)
            }
        } catch {
            NSApp.presentError(error)
        }
    }

    /// The launch window's New Note.
    @objc func newDocument(_ sender: Any?) {
        newNote(sender)
    }

    /// File > New Folder, in the front window's folder or the notes folder.
    @objc func newFolder(_ sender: Any?) {
        do {
            try FileActions.newFolder(in: frontFolder, undo: front?.window?.undoManager)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// File > New Window: another window on the front window's folder, or on the notes folder.
    @objc func newWindow(_ sender: Any?) {
        let folder = Folder(frontFolder)
        Library.noteOpened(folder.url, folder: true)
        MainWindowController(folder: folder).showWindow(nil)
    }

    private var frontNote: MarkdownDocument? {
        NSDocumentController.shared.currentDocument as? MarkdownDocument
    }

    @objc func duplicateNote(_ sender: Any?) {
        guard let url = frontNote?.fileURL else { return }
        do {
            let copy = try FileActions.duplicate(url, undo: front?.window?.undoManager)
            front?.open(copy, newTab: true)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func trashNote(_ sender: Any?) {
        guard let url = frontNote?.fileURL else { return }
        do {
            try FileActions.trash(url, undo: front?.window?.undoManager)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func showEarlierVersions(_ sender: Any?) {
        guard let document = frontNote, let window = document.windowControllers.first?.window else { return }
        EarlierVersions.show(for: document, on: window)
    }

    /// File > Open Inbox: the inbox `dewline capture` appends to, made if it isn't there yet.
    @objc func openInbox(_ sender: Any?) {
        let url = Preferences.shared.inbox
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url, options: .withoutOverwriting)
            }
            try openMarkdown(at: url)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// File > Today's Note: today's file in the notes folder's Daily folder, made if it isn't there yet.
    @objc func openTodaysNote(_ sender: Any?) {
        do {
            try openMarkdown(at: DailyNote.today(in: FileActions.notesFolder))
            DailyNote.noteOpened(defaults: defaults)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func capture(_ sender: Any?) {
        Capture.show()
    }

    /// Settings > Agents > Set Up… and the agent panel's Set Up: installs the hooks after a sheet listing the files.
    @objc func setUpHooks(_ sender: Any?) {
        HookSetup.install(from: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    /// File > Join Shared Note…: the invite link, pasted.
    @objc func joinSharedNote(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Join a shared note"
        alert.informativeText = "Paste the invite link you were sent."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "dewline://join\u{2026}"
        alert.accessoryView = field
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let link = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.hasPrefix("dewline://join") else {
            let refused = NSAlert()
            refused.messageText = "This isn\u{2019}t an invite link."
            refused.informativeText = "An invite link starts with dewline://join. Ask for a new one."
            refused.runModal()
            return
        }
        Collaboration.join(link: link)
    }

    /// File > Print…: the note as its PDF export lays it out.
    @objc func printNote(_ sender: Any?) {
        guard let document = frontNote, let window = document.windowControllers.first?.window,
            let text = (document.windowControllers.first as? MainWindowController)?.textView?.string
        else { return }
        Task {
            do {
                try await Export.print(text, title: document.displayName, folder: document.fileURL?.deletingLastPathComponent(), on: window)
            } catch {
                document.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Note", action: #selector(newNote(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Capture\u{2026}", action: #selector(capture(_:)), keyEquivalent: "").target = self
        if DailyNote.isOn(defaults: defaults) {
            menu.addItem(withTitle: "Today\u{2019}s Note", action: #selector(openTodaysNote(_:)), keyEquivalent: "").target = self
        }
        return menu
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openTodaysNote(_:)):
            item.isHidden = !DailyNote.isOn(defaults: defaults)
            return !item.isHidden
        case #selector(duplicateNote(_:)), #selector(trashNote(_:)), #selector(printNote(_:)):
            return frontNote?.fileURL != nil
        case #selector(showEarlierVersions(_:)):
            return frontNote?.live != nil
        default:
            return true
        }
    }
}
