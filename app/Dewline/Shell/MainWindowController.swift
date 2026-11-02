import AppKit
import MdCore

/// One tab: the sidebar beside the open file, or beside an empty page in a folder window until a file opens. The
/// window is Station's: no toolbar, a title band on the theme's frame, and the sidebar and the editor as two islands.
/// Each tab has its own window; its `TabSet` keeps only the selected one on screen and draws the tab row.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Every tab, kept here because a folder window has no document to own its controller.
    private static var all: Set<MainWindowController> = []

    let folder: Folder?
    /// The folder's Markdown files for Quick Open, shared with the folder's other tabs.
    let index: FolderIndex?
    private let sidebar: SidebarViewController
    private let split = StationSplitController()
    private let band: TitleBand
    /// The editor island: the tab row along its top with the horizon on its bottom edge, the page, and the Keep/Revert
    /// bar along its bottom.
    private let editor = IslandView(.islandEditor)
    private let tabRow = TabRow()
    private let horizon = HorizonView()
    /// This window's tabs, shared with the tabs beside this one.
    private(set) var tabs: TabSet!
    private let keepBar = KeepBar()
    private let page = NSView()
    private var pageContent: NSView?
    /// "Claude finished · 3 places in 2 files · Review", under the tab bar.
    let finished = FinishedLine()
    private(set) var textView: EditorTextView?
    private var outlineUpdate: Task<Void, Never>?
    private var sectionUpdate: Task<Void, Never>?
    private var history = History() {
        didSet { updateNavigation() }
    }
    /// The breadcrumbs' folders and file, one per path item.
    private var crumbURLs: [URL] = []
    private var countUpdate: Task<Void, Never>?
    private var linkUpdate: Task<Void, Never>?
    private var edited = false

    /// A tab beside `neighbor`, in its window, or a window of its own.
    init(folder: Folder?, joining neighbor: MainWindowController? = nil) {
        self.folder = folder
        index = folder.map(FolderIndex.of)
        sidebar = SidebarViewController(folder: folder)
        band = TitleBand(sidebarToggle: split)
        // A plain item, so no system sidebar glass draws under the island; it keeps its width as the window resizes.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 360
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let pageController = NSViewController()
        pageController.view = editor
        let pageItem = NSSplitViewItem(viewController: pageController)
        split.splitViewItems = [sidebarItem, pageItem]
        let root = NSViewController()
        root.view = FrameView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        root.addChild(split)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.contentMinSize = NSSize(width: 560, height: 360)
        // Dewline draws the tabs; the system's tab bar can't take Station's look.
        window.tabbingMode = .disallowed
        // Resume reopens every window at launch, so AppKit restores none.
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Chrome.color(.frame)
        window.identifier = NSUserInterfaceItemIdentifier("Document")
        MainWindowController.lay(band: band, split: split.view, editor: editor, in: root.view, window: window)
        MainWindowController.lay(tabs: tabRow, horizon: horizon, page: page, bar: keepBar, in: editor)
        sidebar.view.setFrameSize(NSSize(width: 248, height: sidebar.view.frame.height))
        if let front = neighbor?.window ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is MainWindowController }) {
            if neighbor == nil {
                window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
            } else {
                window.setFrame(front.frame, display: false)
            }
        } else {
            window.center()
        }
        super.init(window: window)
        if let neighbor {
            tabs = neighbor.tabs
            tabs.insert(self, after: neighbor)
        } else {
            tabs = TabSet(self)
        }
        tabRow.tabs = tabs
        window.delegate = self
        sidebar.open = { [weak self] url, newTab in self?.open(url, newTab: newTab) }
        sidebar.jump = { [weak self] heading in self?.jump(to: heading) }
        band.crumbClicked = { [weak self] index, view in self?.crumbClicked(index, under: view) }
        keepBar.beadX = { [weak horizon] id in horizon?.beadX[id] }
        horizon.beadsMoved = { [weak keepBar] in keepBar?.placeSegment() }
        NotificationCenter.default.addObserver(self, selector: #selector(updatePresence), name: Collaboration.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePresence), name: LiveFile.changesDidChange, object: nil)
        sidebar.reveal = { [weak self] url, match, newTab in self?.reveal(match, in: url, newTab: newTab) }
        Self.all.insert(self)
        if let folder {
            window.title = FileManager.default.displayName(atPath: folder.url.path)
            window.representedURL = folder.url
            let hint = NSTextField(labelWithString: "Choose a Markdown file in the sidebar.")
            hint.font = Chrome.label
            hint.textColor = Chrome.color(.ink3)
            hint.translatesAutoresizingMaskIntoConstraints = false
            let empty = PaperView()
            empty.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
                hint.centerYAnchor.constraint(equalTo: empty.centerYAnchor),
            ])
            setPage(empty)
        }
        updateBreadcrumbs()
        updateNavigation()
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is built in code")
    }

    /// The band across the top of the frame; under it the islands, 6 pt from the window's sides and bottom, and below
    /// the content area's top.
    private static func lay(band: TitleBand, split: NSView, editor: NSView, in frame: NSView, window: NSWindow) {
        for view in [band, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(view)
        }
        let below = split.topAnchor.constraint(equalTo: frame.topAnchor, constant: TitleBand.height)
        below.priority = .defaultLow
        var constraints = [
            band.topAnchor.constraint(equalTo: frame.topAnchor),
            band.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            split.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 6),
            split.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -6),
            split.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -6),
            split.topAnchor.constraint(greaterThanOrEqualTo: band.bottomAnchor),
            below,
        ]
        if let content = window.contentLayoutGuide as? NSLayoutGuide {
            constraints.append(split.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
        band.align(with: editor)
    }

    private static func lay(tabs: TabRow, horizon: HorizonView, page: NSView, bar: KeepBar, in island: NSView) {
        for view in [tabs, page, bar, horizon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            island.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: island.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: island.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: island.trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: TabRow.height),
            // The horizon's line runs along the tab row's bottom edge, over the page's top.
            horizon.centerYAnchor.constraint(equalTo: tabs.bottomAnchor),
            horizon.leadingAnchor.constraint(equalTo: island.leadingAnchor),
            horizon.trailingAnchor.constraint(equalTo: island.trailingAnchor),
            horizon.heightAnchor.constraint(equalToConstant: HorizonView.height),
            page.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: island.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: island.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: island.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: island.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: island.bottomAnchor),
        ])
    }

    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        guard dirtyFlag != edited else { return }
        edited = dirtyFlag
        updateBreadcrumbs()
        tabs?.post()
    }

    /// The tab's name: its file's, or its folder's while the page is empty.
    var tabName: String {
        (document as? NSDocument)?.displayName ?? folder.map { FileManager.default.displayName(atPath: $0.url.path) } ?? "Untitled"
    }

    /// The tab's dot: the writer's color while an agent's changes wait, `ink2` for unsaved edits, else none.
    var tabDot: NSColor? {
        let live = (document as? MarkdownDocument)?.live
        if let change = live?.changes.values.filter(\.marked).min(by: { $0.range.location < $1.range.location }) {
            return MarkWriter(change.origin).color
        }
        return edited ? Chrome.color(.ink2) : nil
    }

    @objc func showNextTab(_ sender: Any?) {
        tabs.tab(1)?.showWindow(sender)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        tabs.tab(-1)?.showWindow(sender)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        band.fullScreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        band.fullScreen(false)
    }

    /// Who is in this file: the agents with changes waiting in it, then the people sharing it.
    @objc private func updatePresence() {
        var people: [(initials: String, writer: Writer)] = []
        if let live = (document as? MarkdownDocument)?.live {
            var writers: [Writer] = []
            for change in live.changes.values.sorted(by: { $0.range.location < $1.range.location }) where change.marked {
                let writer = MarkWriter(change.origin).writer
                if writer != .collaborator, writer != .you, !writers.contains(writer) { writers.append(writer) }
            }
            people += writers.map { writer in
                (writer == .codex ? "X" : String(writer.name.prefix(1)).uppercased(), writer)
            }
        }
        if let document = document as? NSDocument, let share = Collaboration.of(document)?.share {
            people += share.peers.map { peer in
                let words = peer.name.split(separator: " ").prefix(2)
                return (words.map { String($0.prefix(1)).uppercased() }.joined(), Writer.collaborator)
            }
        }
        band.show(people: people)
    }

    /// Selects this tab, in its window's place, and brings it front.
    override func showWindow(_ sender: Any?) {
        tabs.select(self)
        super.showWindow(sender)
        (NSApp.delegate as? AppDelegate)?.closeLaunchWindow()
        if let window { Updates.shared.windowDidShow(window) }
    }

    /// Shows `document` in this tab, closing the one it replaces, and pushes it on the tab's history unless asked not to.
    func display(_ document: MarkdownDocument, pushing: Bool = true) {
        let leaving = place
        let text = document.textView?.string ?? document.takeText()
        if let old = self.document as? NSDocument, old !== document {
            old.removeWindowController(self)
            old.close()
        }
        if self.document !== document {
            document.addWindowController(self)
        }
        let scrollView = EditorTextView.scrollView()
        let header = document.fileURL.flatMap { isAgentFile($0) ? frontMatterLine(of: text) : nil }
        setPage(header.map { frontMatterPage($0, above: scrollView) } ?? scrollView)
        // Rendered blocks fit the column, so the text arrives once the view has its width.
        window?.layoutIfNeeded()
        let textView = scrollView.documentView as! EditorTextView
        textView.documentFolder = document.fileURL?.deletingLastPathComponent()
        textView.noteFolder = folder?.url ?? textView.documentFolder
        textView.openNote = { [weak self] url, heading in self?.follow(url, heading: heading) }
        textView.findInFiles = folder == nil ? nil : { [weak self] tag in self?.sidebar.showSearch(tag) }
        textView.string = text
        // Front matter stays folded until the caret goes into it.
        if let first = textView.styler.map.blocks(in: NSRange(location: 0, length: 0)).first, first.kind == .frontMatter {
            textView.setSelectedRange(NSRange(location: min(NSMaxRange(first.range), (textView.string as NSString).length), length: 0))
        }
        document.live?.attach(textView)
        // The editor's undo history is the document's, which counts its unsaved edits.
        document.undoManager = textView.styler.undoManager
        if let old = self.textView {
            NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: old)
            NotificationCenter.default.removeObserver(self, name: BlockMap.didParse, object: old.styler.map)
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.enclosingScrollView?.contentView)
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: old)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(countWords), name: NSTextView.didChangeSelectionNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(updateOutline), name: BlockMap.didParse, object: textView.styler.map)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        self.textView = textView
        horizon.attach(textView, live: document.live)
        keepBar.attach(textView, live: document.live)
        updatePresence()
        if let url = document.fileURL { ReviewInbox.noteOpened(url) }
        sidebar.show(document.fileURL, headings: outline(of: textView.textStorage!.mutableString, in: textView.styler.map))
        markBrokenLinks()
        if let url = document.fileURL {
            Library.noteOpened(url)
            if pushing { history.visit(url, leaving: leaving) }
        }
        updateBreadcrumbs()
        countWords()
        tabs?.post()
        window?.makeFirstResponder(textView)
    }

    private func setPage(_ content: NSView) {
        pageContent?.removeFromSuperview()
        pageContent = content
        page.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            content.topAnchor.constraint(equalTo: page.topAnchor),
            content.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        // A file's page attaches them again once its text is in.
        horizon.attach(nil, live: nil)
        keepBar.attach(nil, live: nil)
        // Over the page's top, so the text never moves for it.
        finished.removeFromSuperview()
        finished.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(finished)
        NSLayoutConstraint.activate([
            finished.topAnchor.constraint(equalTo: page.topAnchor),
            finished.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            finished.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            finished.heightAnchor.constraint(equalToConstant: FinishedLine.height),
        ])
    }

    /// Opens `url` here, in a new tab when asked or when this tab's text has edits, or selects its tab.
    func open(_ url: URL, newTab: Bool) {
        if let open = NSDocumentController.shared.document(for: url) {
            open.showWindows()
            return
        }
        guard let document = Self.load(url) else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if newTab || hasEdits {
            addTab(document)
        } else {
            display(document)
        }
    }

    private static func load(_ url: URL) -> MarkdownDocument? {
        let controller = NSDocumentController.shared
        do {
            // Agent files such as .mdc rules and .cursorrules open as Markdown too.
            let document = try MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
            controller.addDocument(document)
            return document
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    private var hasEdits: Bool {
        guard let textView, let document = document as? MarkdownDocument else { return false }
        return !document.isUnchanged(textView.string)
    }

    /// Opens a note a link points to and puts the caret on its heading.
    private func follow(_ url: URL, heading: String?) {
        open(url, newTab: false)
        guard let heading, let controller = NSDocumentController.shared.document(for: url)?.windowControllers.first as? MainWindowController else { return }
        controller.textView?.jump(toHeading: heading)
    }

    override func newWindowForTab(_ sender: Any?) {
        let document = MarkdownDocument()
        NSDocumentController.shared.addDocument(document)
        addTab(document)
    }

    @discardableResult
    private func addTab(_ document: MarkdownDocument) -> MainWindowController {
        let tab = MainWindowController(folder: folder, joining: self)
        tab.display(document)
        tab.showWindow(nil)
        return tab
    }

    /// Scrolls the heading's line to the top of the page and puts the caret on it.
    func jump(to heading: Heading) {
        guard let textView, let scrollView = textView.enclosingScrollView,
            heading.location < (textView.string as NSString).length,
            let baseline = textView.baseline(at: heading.location)
        else { return }
        if let url = (document as? NSDocument)?.fileURL { history.visit(url, leaving: place) }
        textView.setSelectedRange(NSRange(location: heading.location, length: 0))
        textView.scroll(NSPoint(x: 0, y: baseline - scrollView.contentInsets.top - 56))
        window?.makeFirstResponder(textView)
    }

    // MARK: Back and forward

    /// The caret and the top of the page, or nil without a file on the page.
    var place: Place? {
        guard let textView, let scrollView = textView.enclosingScrollView else { return nil }
        let visible = textView.visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text, so the probe stays below it.
        let top = textView.characterIndexForInsertion(
            at: NSPoint(x: textView.textContainerOrigin.x + 4, y: max(visible.minY + scrollView.contentInsets.top + 8, textView.textContainerOrigin.y)))
        let baseline = textView.baseline(at: top)
        return Place(caret: textView.selectedRange().location, top: baseline == nil ? 0 : top, offset: visible.minY - (baseline ?? visible.minY))
    }

    /// Puts the caret and the page back where `place` left them.
    func restore(_ place: Place) {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(max(place.caret, 0), length), length: 0))
        let top = min(max(place.top, 0), max(length - 1, 0))
        // Lays the text out to the anchor, so the page is tall enough to scroll there.
        textView.scrollRangeToVisible(NSRange(location: top, length: 0))
        if let baseline = textView.baseline(at: top) {
            textView.scroll(NSPoint(x: 0, y: baseline + place.offset))
        }
    }

    @objc func goBack(_ sender: Any?) {
        go(to: history.back(leaving: place))
    }

    @objc func goForward(_ sender: Any?) {
        go(to: history.forward(leaving: place))
    }

    /// Shows a history entry without pushing it: here, or in a new tab when this tab's text has edits.
    private func go(to entry: History.Entry?) {
        guard let entry else { return }
        var tab = self
        if (document as? NSDocument)?.fileURL?.standardizedFileURL != entry.url.standardizedFileURL {
            if let open = NSDocumentController.shared.document(for: entry.url) {
                open.showWindows()
                return
            }
            guard let document = Self.load(entry.url) else { return }
            if hasEdits {
                tab = addTab(document)
            } else {
                display(document, pushing: false)
            }
        }
        if let place = entry.place { tab.restore(place) }
    }

    private func updateNavigation() {
        band.back.isEnabled = history.canGoBack
        band.forward.isEnabled = history.canGoForward
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): history.canGoBack
        case #selector(goForward(_:)): history.canGoForward
        case #selector(findInFiles(_:)): folder != nil
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)): tabs.tabs.count > 1
        default: true
        }
    }

    // MARK: Breadcrumbs

    private func updateBreadcrumbs() {
        let file = (document as? NSDocument)?.fileURL
        crumbURLs = breadcrumbs(of: file, in: folder?.url)
        var names = crumbURLs.map { FileManager.default.displayName(atPath: $0.path) }
        if names.isEmpty, let name = (document as? NSDocument)?.displayName {
            names = [name]
        }
        band.show(path: names, edited: edited)
        updateMeta()
    }

    /// Lists the Markdown files of the clicked folder, or of the file's folder, under the crumb.
    private func crumbClicked(_ index: Int, under crumb: NSView) {
        guard crumbURLs.indices.contains(index) else { return }
        let file = (document as? NSDocument)?.fileURL?.standardizedFileURL
        let url = crumbURLs[index]
        let directory = url == file ? url.deletingLastPathComponent() : url
        let tree = folder.flatMap { $0.url == directory || $0.relativePath(of: directory) != nil ? $0 : nil } ?? Folder(directory)
        let menu = NSMenu()
        for entry in tree.children(of: directory).entries where entry.isMarkdown {
            let item = menu.addItem(withTitle: entry.url.lastPathComponent, action: #selector(openCrumb(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            item.state = entry.url == file ? .on : .off
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Markdown Files", action: nil, keyEquivalent: "")
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: crumb.isFlipped ? crumb.bounds.maxY + 6 : -6), in: crumb)
    }

    @objc private func openCrumb(_ sender: NSMenuItem) {
        open(sender.representedObject as! URL, newTab: false)
    }

    // MARK: Resume

    /// Every window's folder, tabs and places, back to front.
    static func session() -> Session {
        var windows: [Session.Window] = []
        var seen: Set<ObjectIdentifier> = []
        for window in NSApp.orderedWindows.reversed() {
            guard let set = (window.windowController as? MainWindowController)?.tabs, seen.insert(ObjectIdentifier(set)).inserted else { continue }
            let saved = set.tabs.compactMap { tab -> (Session.Tab, MainWindowController)? in
                guard let url = (tab.document as? NSDocument)?.fileURL, let place = tab.place else { return nil }
                return (Session.Tab(path: url.path, place: place), tab)
            }
            let folder = set.tabs.first?.folder?.url.path
            guard folder != nil || !saved.isEmpty else { continue }
            let selected = saved.firstIndex { $0.1 === set.selected } ?? 0
            windows.append(Session.Window(folder: folder, tabs: saved.map(\.0), selected: selected))
        }
        return Session(windows: windows)
    }

    /// Reopens each window of `session` with its tabs, caret and scroll, skipping files and folders that are gone.
    static func resume(_ session: Session) {
        let files = FileManager.default
        for saved in session.windows {
            var isFolder: ObjCBool = false
            let folder = saved.folder.flatMap { files.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue ? Folder(URL(filePath: $0, directoryHint: .isDirectory)) : nil }
            guard saved.folder == nil || folder != nil else { continue }
            var first: MainWindowController?
            var selected: MainWindowController?
            for (index, tab) in saved.tabs.enumerated() {
                let url = URL(filePath: tab.path)
                guard files.fileExists(atPath: tab.path), NSDocumentController.shared.document(for: url) == nil,
                    let document = load(url)
                else { continue }
                let controller = MainWindowController(folder: folder, joining: first?.tabs.tabs.last)
                controller.display(document)
                controller.showWindow(nil)
                if first == nil { first = controller }
                controller.restore(tab.place)
                if index == saved.selected || selected == nil { selected = controller }
            }
            if first == nil, let folder {
                MainWindowController(folder: folder).showWindow(nil)
            }
            selected?.showWindow(nil)
        }
    }

    /// Opens `url` as the sidebar does and selects `match` where the file's text still holds it.
    private func reveal(_ match: TextMatch?, in url: URL, newTab: Bool) {
        open(url, newTab: newTab)
        guard let match, let tab = NSDocumentController.shared.document(for: url)?.windowControllers.first as? MainWindowController,
            let textView = tab.textView
        else { return }
        let text = textView.string as NSString
        let found = (match.preview as NSString).substring(with: match.previewRange)
        guard NSMaxRange(match.range) <= text.length, text.substring(with: match.range) == found else { return }
        tab.window?.makeFirstResponder(textView)
        textView.jump(to: match.range)
    }

    @objc func findInFiles(_ sender: Any?) {
        sidebar.showSearch()
    }

    /// Shows the document's word count in the subtitle, and the selection's beside it, 250 ms after the text or the
    /// selection last changed, once the map has the whole text. It counts on the main thread from the storage itself, a
    /// piece between events, and starts over when the text changes.
    @objc private func countWords() {
        countUpdate?.cancel()
        countUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            while let map = self?.textView?.styler.map, map.parsed < (self?.textView?.textStorage?.length ?? 0), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            var count = (total: 0, selected: 0)
            var (start, version) = (0, self?.textView?.version)
            while !Task.isCancelled, let textView = self?.textView {
                let text = textView.textStorage!.mutableString
                if textView.version != version { (count, start, version) = ((0, 0), 0, textView.version) }
                guard start < text.length else { break }
                let piece = text.paragraphRange(for: NSRange(location: start, length: min(Self.countedPiece, text.length - start)))
                let found = WordCount.count(text, in: piece, blocks: textView.styler.map.blocks(in: piece), selection: textView.selectedRange())
                count = (count.total + found.total, count.selected + found.selected)
                start = NSMaxRange(piece)
                try? await Task.sleep(for: .milliseconds(1))
            }
            guard !Task.isCancelled, let self, let textView = self.textView else { return }
            let words = WordCount.label(total: count.total, selected: textView.selectedRange().length > 0 ? count.selected : nil)
            self.window?.subtitle = words
            self.updateMeta()
        }
    }

    /// The text one step of the word count reads: a millisecond or two of work.
    private static let countedPiece = 1 << 15

    /// The mono line over the text: the file's path in its folder and the word count, `plans / v2.md · 1,204 words`.
    private func updateMeta() {
        guard let textView else { return }
        let names = crumbURLs.map { FileManager.default.displayName(atPath: $0.path) }
        let path = names.isEmpty ? (document as? NSDocument)?.displayName ?? "" : names.joined(separator: " / ")
        textView.metaLine = [path, window?.subtitle ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Lists the headings 300 ms after typing stops, or once a whole parse lands.
    @objc private func textChanged() {
        countWords()
        outlineUpdate?.cancel()
        outlineUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.updateOutline()
            self?.markBrokenLinks()
        }
    }

    /// A dotted underline under each relative link and CLAUDE.md `@import` whose file is missing, or whose import
    /// cycles or runs more than 5 deep. Drawn as rendering attributes, so the text's own attributes stay as they are.
    /// Found off the main thread, so a file's first frame never waits on the search, and drawn only on the text it read.
    private func markBrokenLinks() {
        linkUpdate?.cancel()
        guard let textView else { return }
        guard let url = (document as? MarkdownDocument)?.fileURL else { return underline([], in: textView) }
        let (text, version) = (textView.string, textView.version)
        linkUpdate = Task { [weak self, weak textView] in
            let links = await Task.detached(priority: .utility) { brokenTargets(in: text, path: url.path, home: agentHome) }.value
            guard !Task.isCancelled, let self, let textView, textView === self.textView, textView.version == version else { return }
            underline(links.map(\.range), in: textView)
        }
    }

    private func underline(_ ranges: [NSRange], in textView: EditorTextView) {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.underlineStyle, for: content.documentRange)
        layout.removeRenderingAttribute(.underlineColor, for: content.documentRange)
        for link in ranges {
            guard let start = content.location(content.documentRange.location, offsetBy: link.location),
                let end = content.location(start, offsetBy: link.length),
                let range = NSTextRange(location: start, end: end)
            else { continue }
            layout.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle([.single, .patternDot]).rawValue, for: range)
            layout.addRenderingAttribute(.underlineColor, value: NSColor.systemRed.withAlphaComponent(0.7), for: range)
        }
    }

    @objc private func updateOutline() {
        guard let textView else { return }
        sidebar.updateOutline(outline(of: textView.textStorage!.mutableString, in: textView.styler.map))
    }

    /// Marks the section at the top of the page 160 ms after scrolling stops.
    @objc private func scrolled() {
        sectionUpdate?.cancel()
        sectionUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, let textView = self.textView, let scrollView = textView.enclosingScrollView else { return }
            let top = NSPoint(
                x: textView.textContainerOrigin.x + 4, y: max(textView.visibleRect.minY + scrollView.contentInsets.top + 8, textView.textContainerOrigin.y))
            self.sidebar.markSection(at: textView.characterIndexForInsertion(at: top))
        }
    }

    func windowWillClose(_ notification: Notification) {
        tabs.remove(self)
        Self.all.remove(self)
        Task {
            if Self.all.isEmpty { (NSApp.delegate as? AppDelegate)?.nothingIsOpen() }
        }
    }

    /// Shares the file live (D13): starts the share on first use, then shows the Share sheet.
    @objc func shareDocument(_ sender: Any?) {
        guard let document = document as? MarkdownDocument, let textView, document.fileURL != nil else {
            let alert = NSAlert()
            alert.messageText = "Save the file before sharing it."
            alert.beginSheetModal(for: window!)
            return
        }
        do {
            let collaboration = try Collaboration.host(document, textView: textView)
            window?.contentViewController?.presentAsSheet(ShareSheet(collaboration))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Dewline couldn’t start sharing."
            alert.informativeText = error.message
            alert.beginSheetModal(for: window!)
        }
    }
}

/// A view filled with the theme's paper, following the theme and the appearance.
final class PaperView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("PaperView is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ThemeStore.shared.color(.paper).cgColor
    }

    @objc private func themeDidChange(_ notification: Notification) {
        needsDisplay = true
    }
}
