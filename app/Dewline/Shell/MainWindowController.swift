import AppKit
import MdCore

/// One tab: the sidebar beside the open file, or beside an empty page in a folder window until a file opens.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    /// Every tab, kept here because a folder window has no document to own its controller.
    private static var all: Set<MainWindowController> = []

    let folder: Folder?
    /// The folder's Markdown files for Quick Open, shared with the folder's other tabs.
    let index: FolderIndex?
    private let sidebar: SidebarViewController
    private let page = BackdropView()
    private(set) var textView: EditorTextView?
    private var outlineUpdate: Task<Void, Never>?
    private var sectionUpdate: Task<Void, Never>?

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
        window.isRestorable = folder == nil
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
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is built in code")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        (NSApp.delegate as? AppDelegate)?.closeLaunchWindow()
        if let window { Updates.shared.windowDidShow(window) }
    }

    /// Shows `document` in this tab, closing the one it replaces.
    func display(_ document: MarkdownDocument) {
        if let old = self.document as? NSDocument, old !== document {
            old.removeWindowController(self)
            old.close()
        }
        if self.document !== document {
            document.addWindowController(self)
        }
        let scrollView = EditorTextView.scrollView()
        setPage(scrollView)
        // Rendered blocks fit the column, so the text arrives once the view has its width.
        window?.layoutIfNeeded()
        let textView = scrollView.documentView as! EditorTextView
        textView.documentFolder = document.fileURL?.deletingLastPathComponent()
        textView.string = document.text
        // The editor's undo history is the document's, which counts its unsaved edits.
        document.undoManager = textView.styler.undoManager
        if let old = self.textView {
            NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: old)
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.enclosingScrollView?.contentView)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        self.textView = textView
        if let url = document.fileURL { Review.noteOpened(url) }
        sidebar.show(document.fileURL, text: document.text)
        markBrokenLinks()
        if let url = document.fileURL {
            let folders = folder.flatMap { folder in
                folder.relativePath(of: url).map { [folder.url.lastPathComponent] + $0.split(separator: "/").dropLast().map(String.init) }
            }
            window?.subtitle = (folders ?? [FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)]).joined(separator: " › ")
            Library.noteOpened(url)
        } else {
            window?.subtitle = ""
        }
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
    }

    /// Opens `url` here, in a new tab when asked or when this tab's text has edits, or selects its tab.
    func open(_ url: URL, newTab: Bool) {
        let controller = NSDocumentController.shared
        if let open = controller.document(for: url) {
            open.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            return
        }
        let document: MarkdownDocument
        do {
            document = try MarkdownDocument(contentsOf: url, ofType: controller.typeForContents(of: url))
        } catch {
            presentError(error)
            return
        }
        controller.addDocument(document)
        controller.noteNewRecentDocumentURL(url)
        let edited = textView.map { $0.string != (self.document as? MarkdownDocument)?.text } ?? false
        if newTab || edited {
            addTab(document)
        } else {
            display(document)
        }
    }

    override func newWindowForTab(_ sender: Any?) {
        let document = MarkdownDocument()
        NSDocumentController.shared.addDocument(document)
        addTab(document)
    }

    private func addTab(_ document: MarkdownDocument) {
        let tab = MainWindowController(folder: folder)
        tab.display(document)
        window?.addTabbedWindow(tab.window!, ordered: .above)
        tab.window?.makeKeyAndOrderFront(nil)
    }

    /// Scrolls the heading's line to the top of the page and puts the caret on it.
    private func jump(to heading: Heading) {
        guard let textView, let scrollView = textView.enclosingScrollView,
            heading.location < (textView.string as NSString).length,
            let baseline = textView.baseline(at: heading.location)
        else { return }
        textView.setSelectedRange(NSRange(location: heading.location, length: 0))
        textView.scroll(NSPoint(x: 0, y: baseline - scrollView.contentInsets.top - 56))
        window?.makeFirstResponder(textView)
    }

    @objc private func textChanged() {
        outlineUpdate?.cancel()
        outlineUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let textView = self.textView else { return }
            self.sidebar.updateOutline(textView.string)
            self.markBrokenLinks()
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
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    // Without this method NSToolbar shows no items, though AppKit makes both standard ones itself.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        nil
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
