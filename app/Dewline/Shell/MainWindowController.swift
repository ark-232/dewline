import AppKit
import MdCore

/// One tab: the sidebar beside the open file, or beside an empty page in a folder window until a file opens.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    /// Every tab, kept here because a folder window has no document to own its controller.
    private static var all: Set<MainWindowController> = []

    let folder: Folder?
    /// The folder's Markdown files for Quick Open, shared with the folder's other tabs.
    let index: FolderIndex?
    private let sidebar: SidebarViewController
    private let page = BackdropView()
    /// "Claude finished · 3 places in 2 files · Review", under the tab bar.
    let finished = FinishedLine()
    private(set) var textView: EditorTextView?
    private var outlineUpdate: Task<Void, Never>?
    private var sectionUpdate: Task<Void, Never>?
    private var history = History() {
        didSet { updateNavigation() }
    }
    private weak var navigation: NSToolbarItemGroup?
    private let crumbs = NSPathControl()
    /// The breadcrumbs' folders and file, one per path item.
    private var crumbURLs: [URL] = []
    private var countUpdate: Task<Void, Never>?

    init(folder: Folder?) {
        self.folder = folder
        index = folder.map(FolderIndex.of)
        sidebar = SidebarViewController(folder: folder)
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 360
        let pageController = NSViewController()
        pageController.view = page
        let pageItem = NSSplitViewItem(viewController: pageController)
        pageItem.automaticallyAdjustsSafeAreaInsets = true
        split.splitViewItems = [sidebarItem, pageItem]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.tabbingMode = .preferred
        window.tabbingIdentifier = folder.map { "folder " + $0.url.path } ?? "files"
        // Resume reopens every window at launch, so AppKit restores none.
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.identifier = NSUserInterfaceItemIdentifier("Document")
        if let front = NSApp.orderedWindows.first(where: { $0.windowController is MainWindowController }) {
            window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
        } else {
            window.center()
        }
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.delegate = self
        sidebar.open = { [weak self] url, newTab in self?.open(url, newTab: newTab) }
        sidebar.jump = { [weak self] heading in self?.jump(to: heading) }
        crumbs.pathStyle = .standard
        crumbs.focusRingType = .none
        crumbs.target = self
        crumbs.action = #selector(crumbClicked(_:))
        crumbs.setContentHuggingPriority(.defaultLow, for: .horizontal)
        crumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sidebar.reveal = { [weak self] url, match, newTab in self?.reveal(match, in: url, newTab: newTab) }
        Self.all.insert(self)
        if let folder {
            window.title = FileManager.default.displayName(atPath: folder.url.path)
            window.representedURL = folder.url
            let hint = NSTextField(labelWithString: "Choose a Markdown file in the sidebar.")
            hint.textColor = .tertiaryLabelColor
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
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is built in code")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        (NSApp.delegate as? AppDelegate)?.closeLaunchWindow()
        if let window { Updates.shared.windowDidShow(window) }
    }

    /// Shows `document` in this tab, closing the one it replaces, and pushes it on the tab's history unless asked not to.
    func display(_ document: MarkdownDocument, pushing: Bool = true) {
        let leaving = place
        if let old = self.document as? NSDocument, old !== document {
            old.removeWindowController(self)
            old.close()
        }
        if self.document !== document {
            document.addWindowController(self)
        }
        let scrollView = EditorTextView.scrollView()
        let header = document.fileURL.flatMap { isAgentFile($0) ? frontMatterLine(of: document.text) : nil }
        setPage(header.map { frontMatterPage($0, above: scrollView) } ?? scrollView)
        // Rendered blocks fit the column, so the text arrives once the view has its width.
        window?.layoutIfNeeded()
        let textView = scrollView.documentView as! EditorTextView
        textView.documentFolder = document.fileURL?.deletingLastPathComponent()
        textView.noteFolder = folder?.url ?? textView.documentFolder
        textView.openNote = { [weak self] url, heading in self?.follow(url, heading: heading) }
        textView.string = document.text
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
        if let url = document.fileURL { Review.noteOpened(url) }
        sidebar.show(document.fileURL, headings: outline(of: textView.textStorage!.mutableString, in: textView.styler.map))
        markBrokenLinks()
        if let url = document.fileURL {
            Library.noteOpened(url)
            if pushing { history.visit(url, leaving: leaving) }
        }
        updateBreadcrumbs()
        countWords()
        window?.makeFirstResponder(textView)
    }

    private func setPage(_ content: NSView) {
        page.contentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: page.safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            content.topAnchor.constraint(equalTo: page.safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        // Over the page's top inset, so the text never moves for it.
        finished.removeFromSuperview()
        finished.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(finished)
        NSLayoutConstraint.activate([
            finished.topAnchor.constraint(equalTo: page.safeAreaLayoutGuide.topAnchor),
            finished.leadingAnchor.constraint(equalTo: page.safeAreaLayoutGuide.leadingAnchor),
            finished.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            finished.heightAnchor.constraint(equalToConstant: FinishedLine.height),
        ])
    }

    /// Opens `url` here, in a new tab when asked or when this tab's text has edits, or selects its tab.
    func open(_ url: URL, newTab: Bool) {
        if let open = NSDocumentController.shared.document(for: url) {
            open.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
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
        textView.map { $0.string != (document as? MarkdownDocument)?.text } ?? false
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
        let tab = MainWindowController(folder: folder)
        tab.display(document)
        window?.addTabbedWindow(tab.window!, ordered: .above)
        tab.window?.makeKeyAndOrderFront(nil)
        return tab
    }

    /// Scrolls the heading's line to the top of the page and puts the caret on it.
    private func jump(to heading: Heading) {
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
    private var place: Place? {
        guard let textView, let scrollView = textView.enclosingScrollView else { return nil }
        let visible = textView.visibleRect
        let top = textView.characterIndexForInsertion(
            at: NSPoint(x: textView.textContainerOrigin.x + 4, y: visible.minY + scrollView.contentInsets.top + 8))
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
                open.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
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

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? goBack(sender) : goForward(sender)
    }

    private func updateNavigation() {
        navigation?.subitems.first?.isEnabled = history.canGoBack
        navigation?.subitems.last?.isEnabled = history.canGoForward
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): history.canGoBack
        case #selector(goForward(_:)): history.canGoForward
        case #selector(findInFiles(_:)): folder != nil
        default: true
        }
    }

    // MARK: Breadcrumbs

    private func updateBreadcrumbs() {
        let file = (document as? NSDocument)?.fileURL
        crumbURLs = breadcrumbs(of: file, in: folder?.url)
        func item(_ title: String, image: NSImage?, current: Bool) -> NSPathControlItem {
            let item = NSPathControlItem()
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: current ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            image?.size = NSSize(width: 16, height: 16)
            item.image = image
            return item
        }
        var items = crumbURLs.enumerated().map { index, url in
            item(FileManager.default.displayName(atPath: url.path), image: NSWorkspace.shared.icon(forFile: url.path), current: index == crumbURLs.count - 1)
        }
        if items.isEmpty, let name = (document as? NSDocument)?.displayName {
            items = [item(name, image: nil, current: true)]
        }
        crumbs.pathItems = items
    }

    /// Lists the Markdown files of the clicked folder, or of the file's folder, under the click.
    @objc private func crumbClicked(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem,
            let index = sender.pathItems.firstIndex(where: { $0 === clicked }) ?? sender.pathItems.firstIndex(where: { $0.title == clicked.title }),
            crumbURLs.indices.contains(index)
        else { return }
        let file = (document as? NSDocument)?.fileURL?.standardizedFileURL
        let url = crumbURLs[index]
        let directory = url == file ? url.deletingLastPathComponent() : url
        let tree = folder.flatMap { $0.url == directory || $0.relativePath(of: directory) != nil ? $0 : nil } ?? Folder(directory)
        let menu = NSMenu()
        for entry in tree.children(of: directory).entries where entry.isMarkdown {
            let item = menu.addItem(withTitle: entry.url.lastPathComponent, action: #selector(openCrumb(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            item.image = NSWorkspace.shared.icon(forFile: entry.url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.state = entry.url == file ? .on : .off
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Markdown Files", action: nil, keyEquivalent: "")
        }
        let x = sender.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil).x
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc private func openCrumb(_ sender: NSMenuItem) {
        open(sender.representedObject as! URL, newTab: false)
    }

    // MARK: Resume

    /// Every window's folder, tabs and places, back to front.
    static func session() -> Session {
        var windows: [Session.Window] = []
        var seen: Set<ObjectIdentifier> = []
        for window in NSApp.orderedWindows.reversed() where window.windowController is MainWindowController {
            let group = window.tabGroup?.windows ?? [window]
            guard seen.insert(ObjectIdentifier(group[0])).inserted else { continue }
            // The selected tab is the group's window in front.
            let front = window.tabGroup?.selectedWindow ?? window
            let tabs = group.compactMap { $0.windowController as? MainWindowController }
            let saved = tabs.compactMap { tab -> (Session.Tab, NSWindow)? in
                guard let url = (tab.document as? NSDocument)?.fileURL, let place = tab.place else { return nil }
                return (Session.Tab(path: url.path, place: place), tab.window!)
            }
            let folder = tabs.first?.folder?.url.path
            guard folder != nil || !saved.isEmpty else { continue }
            let selected = saved.firstIndex { $0.1 === front } ?? 0
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
                let controller = MainWindowController(folder: folder)
                controller.display(document)
                if let first {
                    first.window?.addTabbedWindow(controller.window!, ordered: .above)
                } else {
                    controller.showWindow(nil)
                    first = controller
                }
                controller.restore(tab.place)
                if index == saved.selected || selected == nil { selected = controller }
            }
            if first == nil, let folder {
                MainWindowController(folder: folder).showWindow(nil)
            }
            selected?.window?.makeKeyAndOrderFront(nil)
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
    /// selection last changed, counted off the main thread once the map has the whole text.
    @objc private func countWords() {
        countUpdate?.cancel()
        countUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            while let map = self?.textView?.styler.map, map.parsed < (self?.textView?.textStorage?.length ?? 0), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, let self, let textView = self.textView else { return }
            let text = textView.string
            let blocks = textView.styler.map.blocks(in: NSRange(location: 0, length: (text as NSString).length))
            let selection = textView.selectedRange()
            let count = await Task.detached(priority: .utility) { WordCount.count(text, blocks: blocks, selection: selection) }.value
            guard !Task.isCancelled else { return }
            let words = WordCount.label(total: count.total, selected: selection.length > 0 ? count.selected : nil)
            self.window?.subtitle = words
        }
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
    private func markBrokenLinks() {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.underlineStyle, for: content.documentRange)
        layout.removeRenderingAttribute(.underlineColor, for: content.documentRange)
        guard let url = (document as? MarkdownDocument)?.fileURL else { return }
        for link in brokenTargets(in: textView.string, path: url.path, home: agentHome) {
            guard let start = content.location(content.documentRange.location, offsetBy: link.range.location),
                let end = content.location(start, offsetBy: link.range.length),
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
            let top = NSPoint(x: textView.textContainerOrigin.x + 4, y: textView.visibleRect.minY + scrollView.contentInsets.top + 8)
            self.sidebar.markSection(at: textView.characterIndexForInsertion(at: top))
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.all.remove(self)
        Task {
            if Self.all.isEmpty { (NSApp.delegate as? AppDelegate)?.nothingIsOpen() }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .navigation, .breadcrumbs, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    // AppKit makes the standard items itself.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .navigation:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: ["chevron.left", "chevron.right"].map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)! },
                selectionMode: .momentary,
                labels: ["Back", "Forward"],
                target: self,
                action: #selector(navigate(_:))
            )
            group.label = "Back/Forward"
            group.autovalidates = false
            for item in group.subitems { item.autovalidates = false }
            group.subitems.first?.toolTip = "Back"
            group.subitems.last?.toolTip = "Forward"
            navigation = group
            updateNavigation()
            return group
        case .breadcrumbs:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Path"
            item.view = crumbs
            item.isBordered = false
            item.visibilityPriority = .high
            NSLayoutConstraint.activate([
                crumbs.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
                crumbs.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            ])
            return item
        default:
            return nil
        }
    }
}

extension NSToolbarItem.Identifier {
    static let navigation = Self("Navigation")
    static let breadcrumbs = Self("Breadcrumbs")
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
