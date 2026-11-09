import AppKit
import MdCore

/// One tab: the sidebar, the open note in the editor column with the status bar under it, and the right pane. The
/// window is a standard titled window with a unified toolbar; its title is the note's name and its subtitle the note's
/// folder. Each tab has its own window; its `TabSet` keeps only the selected one on screen and draws the tab row.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    /// Every tab, kept here because a folder window has no document to own its controller.
    private static var all: Set<MainWindowController> = []
    /// The notes of tabs closed in this run, newest last, with their windows' folders, for Reopen Closed Tab.
    private static var closed: [(url: URL, folder: Folder?)] = []

    let folder: Folder?
    /// The folder's Markdown files for Quick Open, shared with the folder's other tabs.
    let index: FolderIndex?
    let sidebar: SidebarViewController
    private let split = StationSplitController()
    private let toolbar = WindowToolbar()
    /// The editor column: the tab row, the page, the Keep bar and the status bar, top to bottom.
    private let column = PaperView()
    private let tabRow = TabRow()
    private var tabRowHeight: NSLayoutConstraint!
    /// This window's tabs, shared with the tabs beside this one.
    private(set) var tabs: TabSet!
    private let keepBar = KeepBar()
    private let page = NSView()
    private var pageContent: NSView?
    let statusBar = StatusBar()
    let pane = RightPane()
    private let paneItem: NSSplitViewItem
    /// Whether the editor showed its source before Preview switched it there.
    private var sourceBeforePreview: Bool?
    /// Review's line for a finished agent turn; the Keep bar says it now, so it is never laid out.
    let finished = FinishedLine()
    private(set) var textView: EditorTextView?
    private var linkUpdateAfterTyping: Task<Void, Never>?
    private var history = History() {
        didSet { updateNavigation() }
    }
    private var countUpdate: Task<Void, Never>?
    private var linkUpdate: Task<Void, Never>?
    private var loadsUpdate: Task<Void, Never>?
    private var edited = false
    /// A resumed tab's file and place, read when the tab is first selected.
    private var pending: Session.Tab? {
        didSet { tabs?.post() }
    }

    /// A tab beside `neighbor`, in its window, or a window of its own.
    init(folder: Folder?, joining neighbor: MainWindowController? = nil) {
        self.folder = folder
        index = folder.map(FolderIndex.of)
        sidebar = SidebarViewController(folder: folder)
        // A plain item, so no system sidebar glass draws under it; it keeps its width as the window resizes.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 360
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let columnController = NSViewController()
        columnController.view = column
        let columnItem = NSSplitViewItem(viewController: columnController)
        columnItem.minimumThickness = 360
        paneItem = NSSplitViewItem(viewController: pane)
        paneItem.canCollapse = true
        paneItem.isCollapsed = true
        paneItem.minimumThickness = RightPane.widths.lowerBound
        paneItem.maximumThickness = RightPane.widths.upperBound
        paneItem.holdingPriority = NSLayoutConstraint.Priority(259)
        split.splitViewItems = [sidebarItem, columnItem, paneItem]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.contentMinSize = NSSize(width: 560, height: 360)
        // Dewline draws the tabs, so each keeps its own document, sheets and undo.
        window.tabbingMode = .disallowed
        // Resume reopens every window at launch, so AppKit restores none.
        window.isRestorable = false
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.backgroundColor = Chrome.color(.chrome)
        window.identifier = NSUserInterfaceItemIdentifier("Document")
        MainWindowController.lay(tabs: tabRow, page: page, bar: keepBar, status: statusBar, in: column)
        sidebar.view.setFrameSize(NSSize(width: 240, height: sidebar.view.frame.height))
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
        tabRowHeight = tabRow.heightAnchor.constraint(equalToConstant: 0)
        tabRowHeight.isActive = true
        if let neighbor {
            tabs = neighbor.tabs
            tabs.insert(self, after: neighbor)
            if !neighbor.paneItem.isCollapsed { adoptPane(from: neighbor) }
        } else {
            tabs = TabSet(self)
        }
        tabRow.tabs = tabs
        window.delegate = self
        sidebar.open = { [weak self] url, newTab in self?.open(url, newTab: newTab) }
        sidebar.reveal = { [weak self] url, match, newTab in self?.reveal(match, in: url, newTab: newTab) }
        pane.picked = { [weak self] tab in self?.tabs.tabs.forEach { $0.showPane(tab) } }
        NotificationCenter.default.addObserver(self, selector: #selector(updatePresence), name: Collaboration.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changesChanged), name: LiveFile.changesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tabsChanged), name: TabSet.changed, object: tabs)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        Self.all.insert(self)
        if let folder {
            window.title = FileManager.default.displayName(atPath: folder.url.path)
            window.representedURL = folder.url
            setPage(Self.emptyPage())
        }
        tabsChanged()
        updateTitle()
        updateNavigation()
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is built in code")
    }

    /// The tab row along the column's top, the page, the Keep bar, and the status bar along the bottom.
    private static func lay(tabs: TabRow, page: NSView, bar: KeepBar, status: StatusBar, in column: NSView) {
        for view in [tabs, page, bar, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: column.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            page.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
    }

    /// "No note open", with how to pick or make one.
    private static func emptyPage() -> NSView {
        let hint = NSTextField(wrappingLabelWithString: "No note open. Pick one in the sidebar, or press ⌘N for a new one.")
        hint.font = Chrome.label
        hint.textColor = Chrome.color(.ink2)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        let empty = PaperView()
        empty.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: empty.centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        return empty
    }

    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        guard dirtyFlag != edited else { return }
        edited = dirtyFlag
        updateState()
    }

    /// The note's name without its extension, so the title and its rename popover read as the note.
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        (displayName as NSString).deletingPathExtension.isEmpty ? displayName : (displayName as NSString).deletingPathExtension
    }

    /// The tab's name: its note's, or its folder's while the page is empty.
    var tabName: String {
        if let document = document as? NSDocument { return windowTitle(forDocumentDisplayName: document.displayName) }
        if let pending { return (FileManager.default.displayName(atPath: pending.path) as NSString).deletingPathExtension }
        return folder.map { FileManager.default.displayName(atPath: $0.url.path) } ?? "Untitled"
    }

    /// The tab's dot: the accent while outside changes wait for a decision, else none. The tab row shows it only on a
    /// tab in back.
    var tabDot: NSColor? {
        let live = (document as? MarkdownDocument)?.live
        return live?.changes.values.contains(where: { $0.marked || $0.conflict }) == true ? Chrome.color(.accent) : nil
    }

    @objc func showNextTab(_ sender: Any?) {
        tabs.tab(1)?.showWindow(sender)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        tabs.tab(-1)?.showWindow(sender)
    }

    /// The title is the note's name, set by its document; the subtitle is the folder the note is in.
    private func updateTitle() {
        guard let window else { return }
        let url = (document as? NSDocument)?.fileURL
        let folderURL = url?.deletingLastPathComponent() ?? folder?.url
        window.subtitle = url == nil ? "" : folderURL.map { FileManager.default.displayName(atPath: $0.path) } ?? ""
        if document == nil, pageContent != nil, folder == nil { window.title = "Dewline" }
    }

    /// The Share button's count of people editing with you.
    @objc private func updatePresence() {
        let peers = (document as? NSDocument).flatMap { Collaboration.of($0)?.share.peers.count } ?? 0
        toolbar.showEditing(peers)
        showRequest()
    }

    private static let requestMessage = "share-request"

    /// "Ana asks to join · Approve · Deny" for this window's shared note, so a closed popover still shows the request.
    private func showRequest() {
        guard let document = document as? NSDocument,
            let (collaboration, peer) = Collaboration.asking.first(where: { $0.collaboration.document === document })
        else { return statusBar.clear(Self.requestMessage) }
        statusBar.post(.init(id: Self.requestMessage, kind: .request, text: "\(peer.name) asks to join", actions: [
            .init(title: "Approve") { _ in collaboration.share.approve(peer.id) },
            .init(title: "Deny") { _ in collaboration.share.deny(peer.id) },
        ]))
    }

    @objc private func changesChanged() {
        updateState()
        let live = (document as? MarkdownDocument)?.live
        pane.changesCount = live?.changes.values.count(where: { $0.marked || $0.conflict }) ?? 0
    }

    /// The tab row shows with two tabs or more.
    @objc private func tabsChanged() {
        let shows = tabs.tabs.count > 1
        tabRow.isHidden = !shows
        tabRowHeight.constant = shows ? TabRow.height : 0
    }

    @objc private func themeDidChange() {
        window?.backgroundColor = Chrome.color(.chrome)
    }

    /// The status bar's left side: a terminal waiting, a conflict holding the save, or Saved.
    private func updateState() {
        guard let document = document as? MarkdownDocument else { return statusBar.show(state: "") }
        if document.isAwaited {
            statusBar.show(state: "A terminal is waiting for this note", action: .init(title: "Done") { [weak self] _ in
                self?.window?.performClose(nil)
            })
        } else if document.live?.changes.values.contains(where: \.conflict) == true {
            statusBar.show(state: "Saving waits until you choose")
        } else {
            statusBar.show(state: "Saved")
        }
    }

    /// Selects this tab, in its window's place, and brings it front.
    override func showWindow(_ sender: Any?) {
        let place = readPending()
        tabs.select(self)
        super.showWindow(sender)
        (NSApp.delegate as? AppDelegate)?.closeLaunchWindow()
        if let window { Updates.shared.windowDidShow(window) }
        shown(at: place)
    }

    /// Selects this tab and puts its window just behind `front`.
    func show(behind front: NSWindow) {
        let place = readPending()
        tabs.select(self)
        window?.order(.below, relativeTo: front.windowNumber)
        shown(at: place)
    }

    /// Reads a resumed tab's file into it, returning the place to restore once the window is up.
    private func readPending() -> Place? {
        guard let tab = pending else { return nil }
        pending = nil
        let url = URL(filePath: tab.path)
        guard NSDocumentController.shared.document(for: url) == nil, let document = Self.load(url) else { return nil }
        display(document)
        return tab.place
    }

    private func shown(at place: Place?) {
        if let place { restore(place) }
        sidebar.fillAfterFirstFrame()
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
            textView.setSelectedRange(NSRange(location: min(NSMaxRange(first.range), textView.textStorage!.length), length: 0))
        }
        document.live?.attach(textView)
        // The editor's undo history is the document's, which counts its unsaved edits.
        document.undoManager = textView.styler.undoManager
        if let old = self.textView {
            NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: old)
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.enclosingScrollView?.contentView)
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: old)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(countWords), name: NSTextView.didChangeSelectionNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        self.textView = textView
        keepBar.attach(textView, live: document.live)
        if !paneItem.isCollapsed, pane.tab == .preview {
            sourceBeforePreview = textView.styler.showsSource
            if !textView.styler.showsSource { textView.toggleSource(nil) }
            pane.preview.show(textView)
        }
        updatePresence()
        changesChanged()
        if let url = document.fileURL { ReviewInbox.noteOpened(url) }
        sidebar.show(document.fileURL)
        markBrokenLinks()
        if let url = document.fileURL {
            Library.noteOpened(url)
            if pushing { history.visit(url, leaving: leaving) }
        }
        updateTitle()
        countWords()
        countLoads()
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
        // A note's page attaches it again once its text is in.
        keepBar.attach(nil, live: nil)
    }

    /// Opens `url` here, in a new tab when asked or when this tab's text has edits or a terminal waits on it, or
    /// selects its tab.
    func open(_ url: URL, newTab: Bool) {
        if let open = NSDocumentController.shared.document(for: url) {
            open.showWindows()
            return
        }
        guard let document = Self.load(url) else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if newTab || hasEdits || (self.document as? MarkdownDocument)?.isAwaited == true {
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

    /// Opens the note of the tab closed last, in a new tab of this window.
    @objc func reopenClosedTab(_ sender: Any?) {
        while let last = Self.closed.popLast() {
            guard FileManager.default.fileExists(atPath: last.url.path) else { continue }
            if let open = NSDocumentController.shared.document(for: last.url) {
                open.showWindows()
            } else if let document = Self.load(last.url) {
                addTab(document)
            }
            return
        }
    }

    /// Scrolls the heading's line to the top of the page and puts the caret on it.
    func jump(to heading: Heading) {
        guard let textView, let scrollView = textView.enclosingScrollView,
            heading.location < textView.textStorage!.length,
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

    /// Puts the caret and the page back where `place` left them. The baseline TextKit 2 first reports is an estimate
    /// the next layout replaces, so `hold` lays out, scrolls, and lays out again before it settles.
    func restore(_ place: Place) {
        guard let textView else { return }
        let length = textView.textStorage!.length
        textView.setSelectedRange(NSRange(location: min(max(place.caret, 0), length), length: 0))
        let top = min(max(place.top, 0), max(length - 1, 0))
        // Lays the text out to the anchor, so the page is tall enough to scroll there.
        textView.scrollRangeToVisible(NSRange(location: top, length: 0))
        textView.hold(top, at: -place.offset)
        // Past the first screen the text styles once the whole parse lands, and that pass keeps this line in place.
        textView.styler.restored = textView.styler.hasUnstyledText ? top : nil
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
        window?.toolbar?.validateVisibleItems()
    }

    private func validates(_ action: Selector?) -> Bool {
        switch action {
        case #selector(goBack(_:)): history.canGoBack
        case #selector(goForward(_:)): history.canGoForward
        case #selector(findInFiles(_:)): folder != nil
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)): tabs.tabs.count > 1
        case #selector(reopenClosedTab(_:)): !Self.closed.isEmpty
        case #selector(shareDocument(_:)), #selector(shareNote(_:)): (document as? NSDocument)?.fileURL != nil
        default: true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let open = !paneItem.isCollapsed
        switch menuItem.action {
        case #selector(togglePreview(_:)): menuItem.state = open && pane.tab == .preview ? .on : .off
        case #selector(toggleAgent(_:)): menuItem.state = open && pane.tab == .agent ? .on : .off
        case #selector(toggleChanges(_:)): menuItem.state = open && pane.tab == .changes ? .on : .off
        default: break
        }
        return validates(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validates(item.action)
    }

    // MARK: Right pane

    @objc func togglePreview(_ sender: Any?) {
        togglePane(.preview)
    }

    @objc func toggleAgent(_ sender: Any?) {
        togglePane(.agent)
    }

    @objc func toggleChanges(_ sender: Any?) {
        togglePane(.changes)
    }

    private func togglePane(_ tab: RightPane.Tab) {
        if !paneItem.isCollapsed, pane.tab == tab {
            for each in tabs.tabs { each.hidePane() }
        } else {
            for each in tabs.tabs { each.showPane(tab) }
        }
    }

    /// Opens the right pane on `tab`. A window too narrow for the sidebar, a 480 pt page and the pane loses the sidebar.
    func showPane(_ tab: RightPane.Tab) {
        let sidebarItem = split.splitViewItems[0]
        if paneItem.isCollapsed, !sidebarItem.isCollapsed, let window,
            window.frame.width < sidebar.view.frame.width + 480 + RightPane.width
        {
            sidebarItem.isCollapsed = true
        }
        pane.select(tab)
        if paneItem.isCollapsed {
            paneItem.isCollapsed = false
            split.splitView.setPosition(split.splitView.bounds.width - RightPane.width, ofDividerAt: 1)
        }
        previewShown(pane.tab == .preview)
    }

    func hidePane() {
        paneItem.isCollapsed = true
        previewShown(false)
    }

    /// Takes the pane's state from the tab this one replaces, so every tab in a window shows the same pane.
    func adoptPane(from other: MainWindowController) {
        if other.paneItem.isCollapsed {
            if !paneItem.isCollapsed { hidePane() }
            return
        }
        pane.select(other.pane.tab)
        if paneItem.isCollapsed { paneItem.isCollapsed = false }
        split.splitView.setPosition(split.splitView.bounds.width - other.pane.view.frame.width, ofDividerAt: 1)
        previewShown(pane.tab == .preview)
    }

    /// While Preview shows, the editor shows the source; closing it puts back the mode the editor had.
    private func previewShown(_ shown: Bool) {
        guard let textView else { return }
        if shown, sourceBeforePreview == nil {
            sourceBeforePreview = textView.styler.showsSource
            if !textView.styler.showsSource { textView.toggleSource(nil) }
            pane.preview.show(textView)
        } else if !shown, let was = sourceBeforePreview {
            sourceBeforePreview = nil
            if textView.styler.showsSource != was { textView.toggleSource(nil) }
            pane.preview.show(nil)
        }
    }

    // MARK: Resume

    /// Every window's folder, tabs and places, back to front.
    static func session() -> Session {
        var windows: [Session.Window] = []
        var seen: Set<ObjectIdentifier> = []
        for window in NSApp.orderedWindows.reversed() {
            guard let set = (window.windowController as? MainWindowController)?.tabs, seen.insert(ObjectIdentifier(set)).inserted else { continue }
            let saved = set.tabs.compactMap { tab -> (Session.Tab, MainWindowController)? in
                if let pending = tab.pending { return (pending, tab) }
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

    /// Reopens each window of `session` with its tabs, skipping files and folders that are gone. Only each window's
    /// selected tab reads its file, with its caret and scroll; the others read theirs when first selected. With
    /// `front`, the windows open behind it.
    static func resume(_ session: Session, behind front: NSWindow? = nil) {
        let files = FileManager.default
        for saved in session.windows {
            var isFolder: ObjCBool = false
            let folder = saved.folder.flatMap { files.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue ? Folder(URL(filePath: $0, directoryHint: .isDirectory)) : nil }
            guard saved.folder == nil || folder != nil else { continue }
            var last: MainWindowController?
            var selected: MainWindowController?
            for (index, tab) in saved.tabs.enumerated() {
                guard files.fileExists(atPath: tab.path), NSDocumentController.shared.document(for: URL(filePath: tab.path)) == nil else { continue }
                let controller = MainWindowController(folder: folder, joining: last)
                controller.pending = tab
                last = controller
                if index == saved.selected || selected == nil { selected = controller }
            }
            if let tab = selected ?? folder.map({ MainWindowController(folder: $0) }) {
                if let front { tab.show(behind: front) } else { tab.showWindow(nil) }
            }
        }
    }

    /// Opens `url` as the sidebar does and selects `match` where the file's text still holds it.
    private func reveal(_ match: TextMatch?, in url: URL, newTab: Bool) {
        open(url, newTab: newTab)
        guard let match, let tab = NSDocumentController.shared.document(for: url)?.windowControllers.first as? MainWindowController,
            let textView = tab.textView
        else { return }
        let text = textView.textStorage!.mutableString
        let found = (match.preview as NSString).substring(with: match.previewRange)
        guard NSMaxRange(match.range) <= text.length, text.substring(with: match.range) == found else { return }
        tab.window?.makeFirstResponder(textView)
        textView.jump(to: match.range)
    }

    @objc func findInFiles(_ sender: Any?) {
        sidebar.showSearch()
    }

    /// Shows the note's word count in the status bar, and the selection's beside it, 250 ms after the text or the
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
            self.statusBar.show(words: WordCount.label(total: count.total, selected: textView.selectedRange().length > 0 ? count.selected : nil))
        }
    }

    /// The text one step of the word count reads: a millisecond or two of work.
    private static let countedPiece = 1 << 15

    /// "Agents read 2 files here" in the status bar, when agents load instruction files for the note's folder; a click
    /// lists each agent and file with its estimate. Read off the main thread.
    private func countLoads() {
        loadsUpdate?.cancel()
        guard let directory = (document as? NSDocument)?.fileURL?.deletingLastPathComponent() else {
            return statusBar.clear(Self.loadsMessage)
        }
        let root = folder?.url
        loadsUpdate = Task { [weak self] in
            let rows = await Task.detached(priority: .utility) { whatLoadsRows(in: directory, root: root) }.value
            guard !Task.isCancelled, let self else { return }
            let files = Set(rows.compactMap(\.url)).count
            guard files > 0 else { return self.statusBar.clear(Self.loadsMessage) }
            let title = "Agents read \(files) \(files == 1 ? "file" : "files") here"
            self.statusBar.post(.init(id: Self.loadsMessage, kind: .info, text: "", actions: [.init(title: title) { view in
                LoadsPopover.show(rows, under: view)
            }]))
        }
    }

    private static let loadsMessage = "loads"

    /// Checks links 300 ms after typing stops. The preview takes the text, and a result shown until the next
    /// keystroke goes.
    @objc private func textChanged() {
        countWords()
        statusBar.typed()
        if !paneItem.isCollapsed, pane.tab == .preview { pane.preview.textChanged() }
        linkUpdateAfterTyping?.cancel()
        linkUpdateAfterTyping = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
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
        let (text, version) = (TextCopy(textView.textStorage!.mutableString), textView.version)
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
            layout.addRenderingAttribute(.underlineColor, value: Chrome.color(.ink2), for: range)
        }
    }

    /// The preview follows the page as it scrolls.
    @objc private func scrolled() {
        if !paneItem.isCollapsed, pane.tab == .preview { pane.preview.follow() }
    }

    func windowWillClose(_ notification: Notification) {
        if let url = (document as? NSDocument)?.fileURL { Self.closed.append((url, folder)) }
        tabs.remove(self)
        Self.all.remove(self)
        Task {
            if Self.all.isEmpty { (NSApp.delegate as? AppDelegate)?.nothingIsOpen() }
        }
    }

    /// Shares the note live (D13): starts the share on first use, then shows the Share sheet.
    /// Share: a popover under the toolbar button, where nothing is shared until Copy Invite Link.
    @objc func shareDocument(_ sender: Any?) {
        guard let document = document as? MarkdownDocument, document.fileURL != nil, let content = window?.contentView else { return NSSound.beep() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = Collaboration.sharePopover(for: document)
        if let item = sender as? NSToolbarItem, window?.toolbar?.isVisible == true {
            popover.show(relativeTo: item)
        } else {
            let corner = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 1, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
    }

    /// File > Share….
    @objc func shareNote(_ sender: Any?) {
        shareDocument(sender)
    }
}

/// What agents load for the note's folder, under the status bar's line: each agent with its total, then its files.
@MainActor
private enum LoadsPopover {
    static func show(_ rows: [AgentRow], under view: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows {
            let name = NSTextField(labelWithString: row.title)
            name.font = row.url == nil ? Chrome.labelStrong : Chrome.label
            name.textColor = Chrome.color(.ink)
            name.lineBreakMode = .byTruncatingMiddle
            name.toolTip = row.tip
            let detail = NSTextField(labelWithString: row.detail)
            detail.font = Chrome.status
            detail.textColor = Chrome.color(.ink2)
            let line = NSStackView(views: [name, detail])
            line.spacing = 12
            if row.url == nil, stack.arrangedSubviews.count > 0 { stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!) }
            stack.addArrangedSubview(line)
        }
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = stack.fittingSize
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
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

extension NSWindow {
    /// Draws the window now and commits the frame, then runs `body` on a later turn of the main run loop, so
    /// nothing `body` does holds back this frame.
    func afterDrawing(_ body: @escaping @MainActor () -> Void) {
        displayIfNeeded()
        CATransaction.flush()
        Task { @MainActor in body() }
    }
}
