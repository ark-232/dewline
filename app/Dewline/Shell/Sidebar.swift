import AppKit
import MdCore
import Quartz
import UniformTypeIdentifiers

/// A row in the sidebar.
@MainActor
final class SidebarNode {
    enum Kind {
        /// The open folder's own row, over its tree.
        case root(URL)
        /// A header: Pinned, or a folderless window's Outline.
        case section(String)
        /// A file or folder in the open folder's tree.
        case entry(FolderEntry)
        /// A pinned file or folder.
        case shortcut(FolderEntry)
        case heading(Heading)
        /// The last row of a folder: what its .gitignore hides.
        case ignored([String])
        /// The row after the first 12 headings that shows the rest.
        case more(Int)
    }

    let kind: Kind
    /// Nil until a folder first expands.
    var children: [SidebarNode]?

    init(_ kind: Kind, children: [SidebarNode]? = nil) {
        self.kind = kind
        self.children = children
    }

    var url: URL? {
        switch kind {
        case .root(let url): url
        case .entry(let entry), .shortcut(let entry): entry.url
        default: nil
        }
    }
}

/// The file commands the sidebar sends up the responder chain, each from a menu item whose represented object is the
/// row's URL: the folder to make a note or folder in, or the file to rename, duplicate or trash. FileActions answers
/// them; until something does, their menu items show disabled.
@MainActor
enum FileCommand {
    static let newNote = Selector(("newNoteInFolder:"))
    static let newFolder = Selector(("newFolderInFolder:"))
    /// The represented object is a `NewNoteRequest`.
    static let newNamedNote = Selector(("newNoteNamed:"))
    /// The represented object is a `RenameRequest`.
    static let rename = Selector(("renameItem:"))
    static let duplicate = Selector(("duplicateItem:"))
    static let trash = Selector(("trashItem:"))
    /// The represented object is a `MoveRequest`.
    static let move = Selector(("moveItems:"))

    /// Sends `command` for `object` from `view`'s window, as a menu item would.
    @discardableResult
    static func send(_ command: Selector, _ object: Any, from view: NSView?) -> Bool {
        let item = NSMenuItem(title: "", action: command, keyEquivalent: "")
        item.representedObject = object
        return NSApp.sendAction(command, to: nil, from: item)
    }
}

/// A rename typed into a sidebar row: the file and its new name, extension included.
struct RenameRequest {
    let url: URL
    let name: String
}

/// A note to make from Quick Open: the folder and the file's name, extension included.
struct NewNoteRequest {
    let folder: URL
    let name: String
}

/// Rows dragged onto a folder in the sidebar.
struct MoveRequest {
    let urls: [URL]
    let folder: URL
}

/// The open folder under its own name, with New Note and a menu beside it, and its tree under it; Pinned above it
/// when something is pinned. A window with no folder says so, offers Open Folder, and lists the note's headings. A
/// folder's window can show Find in Files in place of the tree.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate, QLPreviewPanelDataSource
{
    var open: (URL, _ newTab: Bool) -> Void = { _, _ in }
    var jump: (Heading) -> Void = { _ in }
    /// Opens a file from Find in Files, at a match when there is one.
    var reveal: (URL, TextMatch?, _ newTab: Bool) -> Void = { _, _, _ in }

    private let folder: Folder?
    private let find: FindInFilesController?
    private let outlineView = SidebarOutlineView()
    private let pinned = SidebarNode(.section("Pinned"))
    private let outlineSection = SidebarNode(.section("Outline"), children: [])
    /// The folder's row; its children are the tree. Listed after the window's first frame.
    private var tree: SidebarNode?
    private var expandedOnce: Set<ObjectIdentifier> = []
    /// The open file's row in the tree.
    private var fileNode: SidebarNode?
    private var headings: [Heading] = []
    private var showsAllHeadings = false
    /// The location of the heading whose section is at the top of the page.
    private var section: Int?
    private var watch: FolderWatch?
    private var showsIgnored: Bool
    /// The rows are listed once the window has drawn its first frame; until then the sidebar shows empty.
    private var filled = false
    /// The open file as `show` last had it before the rows were listed.
    private var waiting: URL??
    /// The row whose name is being edited.
    private var renaming: SidebarNode?
    /// The file Quick Look shows.
    private var looking: URL?

    init(folder: Folder?) {
        self.folder = folder
        find = folder.map(FindInFilesController.init)
        showsIgnored = Preferences.shared.showsIgnored
        super.init(nibName: nil, bundle: nil)
        find?.reveal = { [weak self] url, match, newTab in self?.reveal(url, match, newTab) }
        find?.close = { [weak self] in self?.showFiles() }
        watch = folder.map { folder in
            FolderWatch([folder.url]) { [weak self] folders in
                let changed = Set(folders.map(\.standardizedFileURL.path))
                self?.relist { changed.contains($0.path) }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarViewController is built in code")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 12
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.returnPressed = { [weak self] in self?.renameSelected() }
        outlineView.clickedWithoutSelecting = { [weak self] node in
            switch node.kind {
            case .heading(let heading):
                self?.jump(heading)
            case .more:
                self?.showsAllHeadings = true
                self?.listHeadings()
            case .ignored:
                self?.showsIgnored.toggle()
                self?.relist { _ in true }
            default:
                return false
            }
            return true
        }
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 8, right: 0)
        let root = ChromeFill(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        var top = root.topAnchor
        if folder == nil {
            let empty = Self.noFolder()
            empty.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
                empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                empty.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            ])
            top = empty.bottomAnchor
        }
        if let find { addChild(find) }
        for content in [scrollView] + (find.map { [$0.view] } ?? []) {
            content.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: top, constant: folder == nil ? 10 : 0),
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        find?.view.isHidden = true
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: Library.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)
    }

    /// "No folder open" over an Open Folder button.
    private static func noFolder() -> NSView {
        let label = NSTextField(labelWithString: "No folder open")
        label.font = Chrome.label
        label.textColor = Chrome.color(.ink2)
        let button = NSButton(title: "Open Folder…", target: nil, action: #selector(AppDelegate.openFolder(_:)))
        button.bezelStyle = .push
        button.controlSize = .regular
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    /// Lists the rows after the window's first frame, so they never hold it back; they appear in the next one.
    func fillAfterFirstFrame() {
        guard !filled, let window = view.window else { return }
        window.afterDrawing { [weak self] in self?.fill() }
    }

    private func fill() {
        guard !filled else { return }
        filled = true
        tree = folder.map { folder in
            let listing = folder.children(of: folder.url, showingIgnored: showsIgnored)
            let rows = listing.entries.map { SidebarNode(.entry($0)) }
            return SidebarNode(.root(folder.url), children: rows + (listing.ignored.isEmpty ? [] : [SidebarNode(.ignored(listing.ignored))]))
        }
        libraryChanged()
        if let folder {
            for path in UserDefaults.standard.stringArray(forKey: "Expanded " + folder.url.path) ?? [] {
                _ = treeNode(for: folder.url.appending(path: path))
            }
        }
        if let waiting { show(waiting, headings: headings) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    /// Shows Find in Files in place of the tree, with its field focused, opening the sidebar when it is collapsed.
    func showSearch(_ query: String? = nil) {
        guard let find else { return }
        (parent as? NSSplitViewController)?.splitViewItem(for: self)?.isCollapsed = false
        outlineView.enclosingScrollView?.isHidden = true
        find.view.isHidden = false
        find.begin(query)
    }

    private func showFiles() {
        find?.view.isHidden = true
        outlineView.enclosingScrollView?.isHidden = false
        view.window?.makeFirstResponder(outlineView)
    }

    /// Shows `url` as the open file: reveals and selects its row. A window without a folder lists its headings.
    func show(_ url: URL?, headings: [Heading]) {
        guard filled else {
            waiting = url
            self.headings = headings
            return
        }
        fileNode = url.flatMap(treeNode(for:))
        showsAllHeadings = false
        section = nil
        updateOutline(headings)
        if let fileNode { outlineView.scrollRowToVisible(outlineView.row(forItem: fileNode)) }
        selectOpenFile()
    }

    /// The open file's row is the selected one, through reloads and relisting.
    private func selectOpenFile() {
        let row = fileNode.map { outlineView.row(forItem: $0) } ?? -1
        if row >= 0 {
            if outlineView.selectedRow != row { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            outlineView.deselectAll(nil)
        }
    }

    func updateOutline(_ headings: [Heading]) {
        self.headings = headings
        guard folder == nil else { return }
        listHeadings()
    }

    private func listHeadings() {
        var rows = headings.map { SidebarNode(.heading($0)) }
        if rows.count > 12, !showsAllHeadings {
            rows = rows.prefix(12) + [SidebarNode(.more(rows.count))]
        }
        outlineSection.children = rows
        reload()
    }

    /// Sets in medium the heading whose section holds `location`.
    func markSection(at location: Int) {
        guard folder == nil else { return }
        let current = headings.last { $0.location <= location }?.location
        guard current != section else { return }
        section = current
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? SidebarCell,
                case .heading(let heading) = (outlineView.item(atRow: row) as? SidebarNode)?.kind
            else { return }
            cell.show(heading, current: heading.location == current)
        }
    }

    private var sections: [SidebarNode] {
        let main = tree ?? (outlineSection.children!.isEmpty ? nil : outlineSection)
        return ((pinned.children ?? []).isEmpty ? [] : [pinned]) + (main.map { [$0] } ?? [])
    }

    private func reload() {
        guard filled else { return }
        outlineView.reloadData()
        for section in sections where expandedOnce.insert(ObjectIdentifier(section)).inserted {
            outlineView.expandItem(section)
        }
        selectOpenFile()
    }

    /// The tree row for `url`, expanding the folders above it.
    private func treeNode(for url: URL) -> SidebarNode? {
        guard let tree, let path = folder?.relativePath(of: url) else { return nil }
        outlineView.expandItem(tree)
        var node = tree
        for name in path.split(separator: "/") {
            guard let child = children(of: node).first(where: { $0.url?.lastPathComponent == String(name) }) else { return nil }
            node = child
            if case .entry(let entry) = child.kind, entry.isFolder {
                outlineView.expandItem(child)
            }
        }
        return node
    }

    /// Lists again each loaded folder that `matches`, keeping the rows that remain so their expansion holds.
    private func relist(_ matches: (URL) -> Bool) {
        guard let folder, let tree else { return }
        func visit(_ node: SidebarNode, _ url: URL) {
            guard let children = node.children else { return }
            if matches(url) {
                let listing = folder.children(of: url, showingIgnored: showsIgnored)
                var kept: [URL: SidebarNode] = [:]
                for child in children {
                    if case .entry(let entry) = child.kind { kept[entry.url] = child }
                }
                node.children = listing.entries.map { kept[$0.url] ?? SidebarNode(.entry($0)) }
                    + (node === tree && !listing.ignored.isEmpty ? [SidebarNode(.ignored(listing.ignored))] : [])
                outlineView.reloadItem(node, reloadChildren: true)
            }
            for child in node.children ?? [] {
                if case .entry(let entry) = child.kind, entry.isFolder { visit(child, entry.url) }
            }
        }
        visit(tree, folder.url)
        if let url = fileNode?.url { fileNode = treeNode(for: url) }
        selectOpenFile()
    }

    private func children(of node: SidebarNode) -> [SidebarNode] {
        if let children = node.children { return children }
        guard case .entry(let entry) = node.kind, entry.isFolder, let folder else { return [] }
        let listing = folder.children(of: entry.url, showingIgnored: showsIgnored)
        let children = listing.entries.map { SidebarNode(.entry($0)) }
        node.children = children
        return children
    }

    @objc private func preferencesChanged() {
        guard Preferences.shared.showsIgnored != showsIgnored else { return }
        showsIgnored = Preferences.shared.showsIgnored
        relist { _ in true }
    }

    @objc private func libraryChanged() {
        guard filled else { return }
        pinned.children = Library.pins.map { url in
            SidebarNode(.shortcut(FolderEntry(url: url, isFolder: url.hasDirectoryPath)))
        }
        reload()
    }

    /// A click opens a note in this tab and a Command-click in a new one; any other file opens in Quick Look.
    @objc private func clicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        switch node.kind {
        case .entry(let entry) where entry.isFolder:
            outlineView.isItemExpanded(node) ? outlineView.collapseItem(node) : outlineView.expandItem(node)
        case .entry(let entry) where entry.isMarkdown || isAgentFile(entry.url):
            open(entry.url, newTab)
        case .entry(let entry):
            quickLook(entry.url)
        case .shortcut(let entry):
            if entry.isFolder {
                (NSApp.delegate as? AppDelegate)?.openFolder(at: entry.url)
            } else {
                open(entry.url, newTab)
            }
        default:
            break
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode,
            case .entry(let entry) = node.kind, entry.isMarkdown
        else { return }
        open(entry.url, true)
    }

    /// A folder's chevron turns as it opens and closes.
    private func reloadChevron(_ node: SidebarNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell,
            case .entry(let entry) = node.kind
        else { return }
        cell.show(entry, gone: false, expanded: outlineView.isItemExpanded(node))
    }

    // MARK: New and the folder's menu

    /// New Note in the folder, from the "+" on the folder's row.
    @objc private func newNote(_ sender: NSButton) {
        guard let url = folder?.url else { return }
        FileCommand.send(FileCommand.newNote, url, from: sender)
    }

    /// New Folder, Show in Finder and Open Another Folder, from the "…" on the folder's row.
    @objc private func folderMenu(_ sender: NSButton) {
        guard let url = folder?.url else { return }
        let menu = NSMenu()
        let new = menu.addItem(withTitle: "New Folder", action: FileCommand.newFolder, keyEquivalent: "")
        new.representedObject = url
        let finder = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        finder.target = self
        finder.representedObject = url
        menu.addItem(withTitle: "Open Another Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode, let url = node.url else { return }
        let isFolder: Bool
        switch node.kind {
        case .root: isFolder = true
        case .entry(let entry), .shortcut(let entry): isFolder = entry.isFolder
        default: return
        }
        func add(_ title: String, _ action: Selector, _ object: Any = url, mine: Bool = false) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = mine ? self : nil
            item.representedObject = object
        }
        if !isFolder, url.pathExtension.lowercased() == "md" || isAgentFile(url) {
            add("Open in New Tab", #selector(openInNewTab(_:)), mine: true)
        }
        let container = isFolder ? url : url.deletingLastPathComponent()
        add("New Note", FileCommand.newNote, container)
        add("New Folder", FileCommand.newFolder, container)
        menu.addItem(.separator())
        if case .entry = node.kind {
            add("Rename", #selector(renameClicked(_:)), node, mine: true)
            add("Duplicate", FileCommand.duplicate)
            add("Move to Trash", FileCommand.trash)
            menu.addItem(.separator())
        }
        let isPinned = Library.pins.contains { $0.path == url.path }
        add(isPinned ? "Unpin" : "Pin", isPinned ? #selector(unpin(_:)) : #selector(pin(_:)), mine: true)
        add("Show in Finder", #selector(showInFinder(_:)), mine: true)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        open(sender.representedObject as! URL, true)
    }

    @objc private func pin(_ sender: NSMenuItem) {
        Library.setPinned(sender.representedObject as! URL, true)
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        Library.setPinned(sender.representedObject as! URL, false)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([sender.representedObject as! URL])
    }

    // MARK: Rename in place

    @objc private func renameClicked(_ sender: NSMenuItem) {
        beginRename(sender.representedObject as! SidebarNode)
    }

    /// Return on a selected file or folder edits its name in place.
    private func renameSelected() {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode, case .entry = node.kind else { return }
        beginRename(node)
    }

    /// Makes the row's name editable, its base name selected.
    func beginRename(_ node: SidebarNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0, let field = (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell)?.textField else { return }
        renaming = node
        field.isEditable = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
        let name = field.stringValue as NSString
        let base = name.deletingPathExtension as NSString
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: base.length == 0 ? name.length : base.length)
    }

    /// Return asks FileActions for the rename; Escape puts the old name back.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = renaming, let url = node.url else { return }
        renaming = nil
        field.isEditable = false
        field.delegate = nil
        let cancelled = (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.stringValue = url.lastPathComponent
        if !cancelled, !name.isEmpty, name != url.lastPathComponent, !name.contains("/") {
            FileCommand.send(FileCommand.rename, RenameRequest(url: url, name: name), from: outlineView)
        }
        view.window?.makeFirstResponder(outlineView)
    }

    // MARK: Quick Look

    private func quickLook(_ url: URL) {
        looking = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        looking != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { looking == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { looking as NSURL? }
    }

    // MARK: Moving rows

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard case .entry(let entry) = (item as! SidebarNode).kind else { return nil }
        return entry.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = dropFolder(item), info.draggingSource as? NSOutlineView === outlineView else { return [] }
        let urls = draggedURLs(info)
        guard !urls.isEmpty, !urls.contains(where: { $0 == target || target.path.hasPrefix($0.path + "/") || $0.deletingLastPathComponent() == target }) else { return [] }
        outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = dropFolder(item) else { return false }
        return FileCommand.send(FileCommand.move, MoveRequest(urls: draggedURLs(info), folder: target), from: outlineView)
    }

    /// The folder a drop on `item` lands in: the row's folder, or the folder of the file it is on.
    private func dropFolder(_ item: Any?) -> URL? {
        switch (item as? SidebarNode)?.kind {
        case .root(let url): url
        case .entry(let entry): entry.isFolder ? entry.url : entry.url.deletingLastPathComponent()
        default: nil
        }
    }

    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Data source and delegate

    func outlineViewItemDidExpand(_ notification: Notification) {
        rememberExpansion(notification, expanded: true)
        (notification.userInfo?["NSObject"] as? SidebarNode).map(reloadChevron)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        rememberExpansion(notification, expanded: false)
        (notification.userInfo?["NSObject"] as? SidebarNode).map(reloadChevron)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if case .entry = (item as! SidebarNode).kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        StationRowView()
    }

    /// Keeps each root's expanded folders in user defaults; collapsing a folder forgets the folders inside it.
    private func rememberExpansion(_ notification: Notification, expanded: Bool) {
        guard let folder, let node = notification.userInfo?["NSObject"] as? SidebarNode,
            case .entry(let entry) = node.kind, entry.isFolder, let path = folder.relativePath(of: entry.url)
        else { return }
        let key = "Expanded " + folder.url.path
        var paths = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if expanded {
            paths.insert(path)
        } else {
            paths = paths.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
        UserDefaults.standard.set(paths.sorted(), forKey: key)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode).map { children(of: $0).count } ?? (filled ? sections.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode).map { children(of: $0)[index] } ?? sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let node = item as! SidebarNode
        switch node.kind {
        case .section, .root: return true
        case .entry(let entry): return entry.isFolder
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        switch (item as! SidebarNode).kind {
        case .entry(let entry), .shortcut(let entry): entry.url.lastPathComponent
        default: nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        switch (item as! SidebarNode).kind {
        case .section, .root: true
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        switch (item as! SidebarNode).kind {
        case .entry, .shortcut: true
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! SidebarNode
        switch node.kind {
        case .root(let url):
            let cell = outlineView.makeView(withIdentifier: SidebarRootCell.identifier, owner: nil) as? SidebarRootCell
                ?? SidebarRootCell(new: (self, #selector(newNote(_:))), menu: (self, #selector(folderMenu(_:))))
            cell.show(FileManager.default.displayName(atPath: url.path), path: (url.path as NSString).abbreviatingWithTildeInPath)
            return cell
        case .section(let title):
            let cell = cell(SidebarCell.header)
            cell.show(title)
            return cell
        case .entry(let entry):
            let cell = cell(SidebarCell.file)
            cell.show(entry, gone: false, expanded: outlineView.isItemExpanded(node))
            return cell
        case .shortcut(let entry):
            let cell = cell(SidebarCell.file)
            cell.show(entry, gone: !FileManager.default.fileExists(atPath: entry.url.path), expanded: false)
            return cell
        case .heading(let heading):
            let cell = cell(SidebarCell.heading)
            cell.show(heading, current: heading.location == section)
            cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Go to Heading") { [weak self] in
                self?.jump(heading)
                return true
            }])
            return cell
        case .ignored(let names):
            let cell = cell(SidebarCell.note)
            cell.textField?.stringValue = showsIgnored ? "Hide what .gitignore hides"
                : names.count > 2 ? "\(names.count) items hidden by .gitignore"
                : names.joined(separator: ", ") + " hidden by .gitignore"
            cell.toolTip = names.joined(separator: "\n")
            cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: showsIgnored ? "Hide Ignored Items" : "Show Ignored Items") { [weak self] in
                self?.showsIgnored.toggle()
                self?.relist { _ in true }
                return true
            }])
            return cell
        case .more(let count):
            let cell = cell(SidebarCell.note)
            cell.textField?.stringValue = "Show all \(count)"
            cell.toolTip = nil
            cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show All Headings") { [weak self] in
                self?.showsAllHeadings = true
                self?.listHeadings()
                return true
            }])
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as! SidebarNode).kind {
        case .root: 28
        case .heading, .more: 22
        default: 24
        }
    }

    private func cell(_ identifier: NSUserInterfaceItemIdentifier) -> SidebarCell {
        outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell ?? SidebarCell(identifier)
    }
}

/// Headings and Show All act on mouse down and never take the selection, which stays on the open file. Rows draw
/// their own chevrons, so the system's disclosure triangles are gone, and every level below the folder indents 12 pt.
/// Return on a row renames it.
private final class SidebarOutlineView: NSOutlineView {
    var clickedWithoutSelecting: (SidebarNode) -> Bool = { _ in false }
    var returnPressed: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if let node = item(atRow: row) as? SidebarNode, clickedWithoutSelecting(node) { return }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            returnPressed()
            return
        }
        super.keyDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        let x = 12 + CGFloat(max(level(forRow: row) - 1, 0)) * indentationPerLevel
        return NSRect(x: x, y: frame.minY, width: max(bounds.width - x - 10, 0), height: frame.height)
    }
}

/// The folder's own row: its name in 13 semibold `ink`, then "+" for a new note and "…" for the folder's menu.
private final class SidebarRootCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("root")

    private let name = NSTextField(labelWithString: "")

    init(new: (AnyObject, Selector), menu: (AnyObject, Selector)) {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = Chrome.labelStrong
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = name
        let plus = Self.button("plus", label: "New Note", target: new.0, action: new.1)
        let more = Self.button("ellipsis", label: "Folder Actions", target: menu.0, action: menu.1)
        for view in [name, plus, more] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: plus.leadingAnchor, constant: -6),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            more.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -2),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarRootCell is built in code")
    }

    private static func button(_ symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    func show(_ title: String, path: String) {
        name.stringValue = title
        toolTip = path
        setAccessibilityLabel("Folder \(title)")
    }

    @objc private func themeDidChange() {
        name.textColor = Chrome.color(.ink)
        for case let button as NSButton in subviews { button.contentTintColor = Chrome.color(.ink2) }
    }
}

/// "now", "2m", "3h", "4d", then the date: short relative times for lists.
func relativeTime(_ date: Date, now: Date = .now) -> String {
    let seconds = now.timeIntervalSince(date)
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
    default: return shortDate(date, now: now)
    }
}

/// One sidebar row: a section label, a file, a heading, or a note. Every file row keeps a 16 pt leading slot, so names
/// line up: empty for a note, a chevron for a folder. Text is `ink2`; the open note's is `ink`.
private final class SidebarCell: NSTableCellView, ChromeSelectable {
    static let header = NSUserInterfaceItemIdentifier("header")
    static let file = NSUserInterfaceItemIdentifier("file")
    static let heading = NSUserInterfaceItemIdentifier("heading")
    static let note = NSUserInterfaceItemIdentifier("note")

    private let chevron = NSImageView()
    private var indent: NSLayoutConstraint?
    /// The text's ink at rest; dimmed rows take `ink3`.
    private var tone: Token = .ink2
    private var current = false

    var selected = false {
        didSet { paint() }
    }

    init(_ identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = Chrome.label
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        addSubview(label)
        chevron.image = Glyph.disclosure.image
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isHidden = true
        addSubview(chevron)
        var constraints = [
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        switch identifier {
        case Self.header:
            label.font = Chrome.section
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4))
        case Self.heading:
            label.font = Chrome.small
            let indent = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
            self.indent = indent
            constraints.append(indent)
        case Self.note:
            label.font = Chrome.small
            tone = .ink3
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20))
        default:
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20))
        }
        NSLayoutConstraint.activate(constraints)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        paint()
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarCell is built in code")
    }

    @objc private func themeDidChange() {
        paint()
    }

    private func paint() {
        chevron.contentTintColor = Chrome.color(.ink2)
        if identifier == Self.header {
            textField?.textColor = Chrome.color(.ink2)
            return
        }
        if identifier == Self.heading {
            textField?.font = current ? .systemFont(ofSize: 12, weight: .medium) : Chrome.small
        }
        textField?.textColor = Chrome.color(selected || current ? .ink : tone)
    }

    /// A file or folder; one that has `gone` from disk, one .gitignore hides, and any file Dewline doesn't edit show
    /// dimmed.
    func show(_ entry: FolderEntry, gone: Bool, expanded: Bool) {
        chevron.image = (expanded ? Glyph.disclosed : Glyph.disclosure).image
        chevron.isHidden = !entry.isFolder
        textField?.stringValue = entry.url.lastPathComponent
        tone = gone || entry.isIgnored || !(entry.isFolder || entry.isMarkdown || isAgentFile(entry.url)) ? .ink3 : .ink2
        toolTip = gone ? "Moved or deleted" : nil
        setAccessibilityLabel(entry.url.lastPathComponent)
        paint()
    }

    func show(_ title: String) {
        textField?.stringValue = title
        paint()
    }

    func show(_ heading: Heading, current: Bool) {
        self.current = current
        textField?.stringValue = heading.title
        indent?.constant = 4 + CGFloat(heading.level - 1) * 10
        tone = .ink2
        paint()
    }
}
