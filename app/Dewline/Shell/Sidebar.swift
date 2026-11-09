import AppKit
import MdCore
import Quartz
import UniformTypeIdentifiers

/// A row in the sidebar.
@MainActor
final class SidebarNode {
    enum Kind {
        /// The open folder, over its tree. A row of its own, "Files", only while Pinned shows above it.
        case root(URL)
        /// A header: Pinned.
        case section(String)
        /// A file or folder in the open folder's tree.
        case entry(FolderEntry)
        /// A pinned file or folder.
        case shortcut(FolderEntry)
        /// The last row of a folder: what its .gitignore hides.
        case ignored([String])
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
/// row's URL: the folder to make a note or folder in, or the file to rename, duplicate or trash. The window answers
/// them through FileActions.
@MainActor
enum FileCommand {
    static let newNote = #selector(MainWindowController.newNoteInFolder(_:))
    static let newFolder = #selector(MainWindowController.newFolderInFolder(_:))
    /// The represented object is a `NewNoteRequest`.
    static let newNamedNote = #selector(MainWindowController.newNoteNamed(_:))
    /// The represented object is a `RenameRequest`.
    static let rename = #selector(MainWindowController.renameItem(_:))
    static let duplicate = #selector(MainWindowController.duplicateItem(_:))
    static let trash = #selector(MainWindowController.trashItem(_:))
    /// The represented object is a `MoveRequest`.
    static let move = #selector(MainWindowController.moveItems(_:))

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

/// A folder's window: a header with the folder's name, New Note, New Folder and Collapse All, and under it the path to
/// the open note's folder; then the tree, with Pinned above it when something is pinned. Indent guides run down each
/// level, darker under the folders that hold the open note, whose names take full ink. A window with no folder says
/// so, offers Open Folder, and lists what is pinned. A folder's window can show Find in Files in place of the tree.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate, QLPreviewPanelDataSource
{
    var open: (URL, _ newTab: Bool) -> Void = { _, _ in }
    /// Opens a file from Find in Files, at a match when there is one.
    var reveal: (URL, TextMatch?, _ newTab: Bool) -> Void = { _, _, _ in }

    private let folder: Folder?
    private let find: FindInFilesController?
    private let outlineView = SidebarOutlineView()
    private let header: SidebarHeader?
    private let pinned = SidebarNode(.section("Pinned"))
    /// The folder's node; its children are the tree. Listed after the window's first frame.
    private var tree: SidebarNode?
    /// The open file's row in the tree.
    private var fileNode: SidebarNode?
    /// The folders between the root and the open file, by standardized path.
    private var onPath: Set<String> = []
    private var watch: FolderWatch?
    private var showsIgnored: Bool
    /// The rows are listed once the window has drawn its first frame; until then the sidebar shows empty.
    private var filled = false
    /// The open file as `show` last had it before the rows were listed.
    private var waiting: URL??
    /// The row whose name is being edited.
    private var renaming: SidebarNode?
    /// Folders that changed on disk while a name was being edited; listed again once it is done, so the editor stays.
    private var changedWhileRenaming: Set<String> = []
    /// The file Quick Look shows.
    private var looking: URL?

    init(folder: Folder?) {
        self.folder = folder
        find = folder.map(FindInFilesController.init)
        header = folder.map { SidebarHeader(root: $0.url) }
        showsIgnored = Preferences.shared.showsIgnored
        super.init(nibName: nil, bundle: nil)
        find?.reveal = { [weak self] url, match, newTab in self?.reveal(url, match, newTab) }
        find?.close = { [weak self] in self?.showFiles() }
        watch = folder.map { folder in
            FolderWatch([folder.url]) { [weak self] folders in
                self?.foldersChanged(Set(folders.map(\.standardizedFileURL.path)))
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
        outlineView.indentationPerLevel = SidebarOutlineView.indent
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
            guard case .ignored = node.kind else { return false }
            self?.toggleIgnored()
            return true
        }
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: header == nil ? 6 : 2, left: 0, bottom: 8, right: 0)
        let root = ChromeFill(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        var top = root.topAnchor
        if let header, let url = folder?.url {
            header.newNote = { [weak self] in _ = FileCommand.send(FileCommand.newNote, url, from: self?.view) }
            header.newFolder = { [weak self] in _ = FileCommand.send(FileCommand.newFolder, url, from: self?.view) }
            header.collapseAll = { [weak self] in self?.collapseAll() }
            header.reveal = { [weak self] url in self?.revealFolder(url) }
            header.contextMenu = { [weak self] in self?.rootMenu() }
            header.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: root.topAnchor),
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            top = header.bottomAnchor
        }
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
        updatePath()
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
        if let waiting { show(waiting) }
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

    /// Shows `url` as the open file: reveals and selects its row, and marks the folders above it.
    func show(_ url: URL?) {
        guard filled else {
            waiting = url
            return
        }
        fileNode = url.flatMap(treeNode(for:))
        updatePath()
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

    // MARK: Where the open file is

    /// The folders from the root down to the open file's, for the header's path and the rows' guides and ink.
    private func updatePath() {
        guard let folder else { return }
        var crumbs: [(String, URL)] = []
        var url = folder.url
        if let open = fileNode?.url, let path = folder.relativePath(of: open) {
            for name in path.split(separator: "/").dropLast() {
                url = url.appending(path: String(name), directoryHint: .isDirectory)
                crumbs.append((String(name), url))
            }
        }
        onPath = Set(crumbs.map { $0.1.standardizedFileURL.path })
        header?.show(crumbs.isEmpty ? [(FileManager.default.displayName(atPath: folder.url.path), folder.url)] : crumbs)
        outlineView.enumerateAvailableRowViews { rowView, row in
            decorate(rowView, row: row)
            guard let node = outlineView.item(atRow: row) as? SidebarNode, case .entry(let entry) = node.kind, entry.isFolder,
                let cell = rowView.view(atColumn: 0) as? SidebarCell
            else { return }
            cell.show(entry, gone: false, expanded: outlineView.isItemExpanded(node), onPath: isOnPath(entry.url))
        }
    }

    private func isOnPath(_ url: URL) -> Bool {
        onPath.contains(url.standardizedFileURL.path)
    }

    /// The row's indent guides: one per level above it, under each enclosing folder's chevron.
    private func decorate(_ rowView: NSTableRowView, row: Int) {
        guard let rowView = rowView as? StationRowView, let node = outlineView.item(atRow: row) as? SidebarNode else { return }
        let depth = outlineView.depth(ofRow: row)
        var guides: [RowGuide] = []
        var ancestor = outlineView.parent(forItem: node) as? SidebarNode
        for level in stride(from: depth - 1, through: 0, by: -1) {
            guides.append(RowGuide(x: SidebarOutlineView.guideX(level), active: ancestor?.url.map(isOnPath) ?? false))
            ancestor = ancestor.flatMap { outlineView.parent(forItem: $0) as? SidebarNode }
        }
        rowView.guides = guides
    }

    /// Expands the folders down to `url` and scrolls its row into view; the root scrolls to the top.
    private func revealFolder(_ url: URL) {
        guard url.standardizedFileURL.path != folder?.url.standardizedFileURL.path, let node = treeNode(for: url) else {
            outlineView.scrollRowToVisible(0)
            return
        }
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.scrollRowToVisible(row) }
    }

    private func collapseAll() {
        for child in tree?.children ?? [] where outlineView.isItemExpanded(child) {
            outlineView.collapseItem(child, collapseChildren: true)
        }
    }

    // MARK: Rows

    /// Whether the top level is section rows (Pinned, then the tree under "Files") rather than the tree itself.
    private var sectioned: Bool {
        folder == nil || !(pinned.children ?? []).isEmpty
    }

    /// The top-level rows: the sections, or the tree's own rows when nothing is pinned.
    private var topLevel: [SidebarNode] {
        guard sectioned else { return tree.map(children(of:)) ?? [] }
        return ((pinned.children ?? []).isEmpty ? [] : [pinned]) + (tree.map { [$0] } ?? [])
    }

    private func reload() {
        guard filled else { return }
        outlineView.sectioned = sectioned
        outlineView.reloadData()
        if sectioned {
            for section in topLevel { outlineView.expandItem(section) }
        }
        selectOpenFile()
    }

    /// The tree row for `url`, expanding the folders above it.
    private func treeNode(for url: URL) -> SidebarNode? {
        guard let tree, let path = folder?.relativePath(of: url) else { return nil }
        if sectioned { outlineView.expandItem(tree) }
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

    /// Folders the watch saw change. They wait while a name is edited, since listing them again would end the edit.
    private func foldersChanged(_ paths: Set<String>) {
        guard renaming == nil else {
            changedWhileRenaming.formUnion(paths)
            return
        }
        relist { paths.contains($0.path) }
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
                if node === tree, !sectioned {
                    outlineView.reloadData()
                } else {
                    outlineView.reloadItem(node, reloadChildren: true)
                }
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

    private func toggleIgnored() {
        showsIgnored.toggle()
        relist { _ in true }
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
        cell.show(entry, gone: false, expanded: outlineView.isItemExpanded(node), onPath: isOnPath(entry.url))
    }

    // MARK: Context menus

    /// The folder's own menu, from the header or the space under the tree: New Note, New Folder, Show in Finder and
    /// Open Another Folder.
    private func rootMenu() -> NSMenu? {
        guard let url = folder?.url else { return nil }
        let menu = NSMenu()
        fillRootMenu(menu, url)
        return menu
    }

    private func fillRootMenu(_ menu: NSMenu, _ url: URL) {
        menu.addItem(withTitle: "New Note", action: FileCommand.newNote, keyEquivalent: "").representedObject = url
        menu.addItem(withTitle: "New Folder", action: FileCommand.newFolder, keyEquivalent: "").representedObject = url
        menu.addItem(.separator())
        let finder = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        finder.target = self
        finder.representedObject = url
        menu.addItem(withTitle: "Open Another Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else {
            if let url = folder?.url { fillRootMenu(menu, url) }
            return
        }
        guard let url = node.url else { return }
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

    /// Lists the new folder at `url` at once, reveals it and makes its name editable.
    func renameNew(_ url: URL) {
        guard filled else { return }
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        relist { $0.standardizedFileURL.path == parent }
        guard let node = treeNode(for: url) else { return }
        outlineView.collapseItem(node)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
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
        if !changedWhileRenaming.isEmpty {
            let changed = changedWhileRenaming
            changedWhileRenaming = []
            relist { changed.contains($0.path) }
        }
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

    /// The folder a drop on `item` lands in: the row's folder, or the folder of the file it is on. A drop between
    /// top-level rows of an unsectioned tree lands in the root.
    private func dropFolder(_ item: Any?) -> URL? {
        guard let node = item as? SidebarNode else { return sectioned ? nil : folder?.url }
        switch node.kind {
        case .root(let url): return url
        case .entry(let entry): return entry.isFolder ? entry.url : entry.url.deletingLastPathComponent()
        default: return nil
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

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        decorate(rowView, row: row)
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
        (item as? SidebarNode).map { children(of: $0).count } ?? (filled ? topLevel.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode).map { children(of: $0)[index] } ?? topLevel[index]
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
        case .root:
            let cell = cell(SidebarCell.header)
            cell.show("Files")
            return cell
        case .section(let title):
            let cell = cell(SidebarCell.header)
            cell.show(title)
            return cell
        case .entry(let entry):
            let cell = cell(SidebarCell.file)
            cell.show(entry, gone: false, expanded: outlineView.isItemExpanded(node), onPath: entry.isFolder && isOnPath(entry.url))
            return cell
        case .shortcut(let entry):
            let cell = cell(SidebarCell.file)
            cell.show(entry, gone: !FileManager.default.fileExists(atPath: entry.url.path), expanded: false, onPath: false)
            return cell
        case .ignored(let names):
            let cell = cell(SidebarCell.note)
            cell.textField?.stringValue = showsIgnored ? "Hide what .gitignore hides"
                : names.count > 2 ? "\(names.count) items hidden by .gitignore"
                : names.joined(separator: ", ") + " hidden by .gitignore"
            cell.toolTip = names.joined(separator: "\n")
            cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: showsIgnored ? "Hide Ignored Items" : "Show Ignored Items") { [weak self] in
                self?.toggleIgnored()
                return true
            }])
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        24
    }

    private func cell(_ identifier: NSUserInterfaceItemIdentifier) -> SidebarCell {
        outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell ?? SidebarCell(identifier)
    }
}

/// The .gitignore row acts on mouse down and never takes the selection, which stays on the open file. Rows draw their
/// own chevrons, so the system's disclosure triangles are gone, and every level of the tree indents 12 pt. Return on a
/// row renames it.
private final class SidebarOutlineView: NSOutlineView {
    static let indent: CGFloat = 12
    /// The leading edge of a top-level row's cell.
    static let inset: CGFloat = 12

    /// The guide for the folder at `depth` runs under its chevron's center: 2 pt in, 6 pt across.
    static func guideX(_ depth: Int) -> CGFloat {
        inset + CGFloat(depth) * indent + 8
    }

    var clickedWithoutSelecting: (SidebarNode) -> Bool = { _ in false }
    var returnPressed: () -> Void = {}
    /// Whether the top level is section rows, so the tree starts a level down.
    var sectioned = false

    /// The row's level within the tree or its section, from 0.
    func depth(ofRow row: Int) -> Int {
        max(level(forRow: row) - (sectioned ? 1 : 0), 0)
    }

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
        let x = Self.inset + CGFloat(depth(ofRow: row)) * indentationPerLevel
        return NSRect(x: x, y: frame.minY, width: max(bounds.width - x - 10, 0), height: frame.height)
    }
}

/// Over a folder's tree: the folder's name in 13 semibold `ink` with New Note, New Folder and Collapse All beside it,
/// then the path to the open note's folder in 12 pt, each folder a button that reveals it, the last in `ink`. At the
/// root the path is the root's name. Right-click gives the folder's menu.
private final class SidebarHeader: NSView {
    var newNote: () -> Void = {}
    var newFolder: () -> Void = {}
    var collapseAll: () -> Void = {}
    var reveal: (URL) -> Void = { _ in }
    var contextMenu: () -> NSMenu? = { nil }

    private let name = NSTextField(labelWithString: "")
    private let path = NSStackView()
    private var separators: [NSTextField] = []

    init(root: URL) {
        super.init(frame: .zero)
        name.font = Chrome.labelStrong
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.stringValue = FileManager.default.displayName(atPath: root.path)
        name.toolTip = (root.path as NSString).abbreviatingWithTildeInPath
        name.setAccessibilityLabel("Folder \(name.stringValue)")
        let buttons = NSStackView(views: [
            Self.button(.newNote, "New Note", shortcut: "⌘N", #selector(newNoteClicked), self),
            Self.button(.newFolder, "New Folder", shortcut: "⇧⌘N", #selector(newFolderClicked), self),
            Self.button(.collapseAll, "Collapse All", shortcut: nil, #selector(collapseAllClicked), self),
        ])
        buttons.spacing = 2
        path.orientation = .horizontal
        path.spacing = 3
        path.setAccessibilityElement(true)
        path.setAccessibilityRole(.group)
        path.setAccessibilityLabel("Current folder")
        for view in [name, buttons, path] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            name.centerYAnchor.constraint(equalTo: topAnchor, constant: 20),
            name.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -6),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            path.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            path.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            path.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            path.heightAnchor.constraint(equalToConstant: 18),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarHeader is built in code")
    }

    private static func button(_ glyph: Glyph, _ label: String, shortcut: String?, _ action: Selector, _ target: AnyObject) -> GlyphButton {
        let button = GlyphButton(glyph, label: label, target: target, action: action)
        button.toolTip = shortcut.map { "\(label) (\($0))" } ?? label
        return button
    }

    /// The folders from the root's first level down to the open note's; a single crumb names the root.
    func show(_ crumbs: [(String, URL)]) {
        for view in path.arrangedSubviews { path.removeArrangedSubview(view); view.removeFromSuperview() }
        separators = []
        for (index, (title, url)) in crumbs.enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: "›")
                separator.font = Chrome.small
                separator.setContentCompressionResistancePriority(.required, for: .horizontal)
                separator.setAccessibilityElement(false)
                separators.append(separator)
                path.addArrangedSubview(separator)
            }
            let crumb = CrumbButton(title, current: index == crumbs.count - 1) { [weak self] in self?.reveal(url) }
            // Earlier folders give up their width first, so the open note's folder stays readable.
            crumb.setContentCompressionResistancePriority(.init(Float(250 + index)), for: .horizontal)
            path.addArrangedSubview(crumb)
        }
        path.toolTip = crumbs.map(\.0).joined(separator: " / ")
        themeDidChange()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu()
    }

    @objc private func newNoteClicked() { newNote() }
    @objc private func newFolderClicked() { newFolder() }
    @objc private func collapseAllClicked() { collapseAll() }

    @objc private func themeDidChange() {
        name.textColor = Chrome.color(.ink)
        for separator in separators { separator.textColor = Chrome.color(.ink3) }
    }
}

/// One folder in the header's path: 12 pt `ink2`, `ink` when it is the open note's folder or under the pointer.
private final class CrumbButton: NSButton {
    private let text: String
    private let current: Bool
    private let onClick: () -> Void
    private var hovering = false {
        didSet { tint() }
    }

    init(_ text: String, current: Bool, onClick: @escaping () -> Void) {
        self.text = text
        self.current = current
        self.onClick = onClick
        super.init(frame: .zero)
        isBordered = false
        (cell as? NSButtonCell)?.highlightsBy = []
        target = self
        action = #selector(clicked)
        cell?.lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        toolTip = "Reveal \(text)"
        setAccessibilityLabel(text)
        setAccessibilityHelp("Reveals the folder in the sidebar")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        tint()
    }

    required init?(coder: NSCoder) {
        fatalError("CrumbButton is built in code")
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    @objc private func clicked() {
        onClick()
    }

    @objc private func themeDidChange() {
        tint()
    }

    private func tint() {
        let color = Chrome.color(current || hovering ? .ink : .ink2)
        attributedTitle = NSAttributedString(string: text, attributes: [.font: current ? NSFont.systemFont(ofSize: 12, weight: .medium) : Chrome.small, .foregroundColor: color])
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

/// One sidebar row: a section label, a file, or a note. Every file row keeps a 16 pt leading slot, so names line up:
/// empty for a note, a chevron for a folder. Text is `ink2`; the open note's and the folders above it are `ink`.
private final class SidebarCell: NSTableCellView, ChromeSelectable {
    static let header = NSUserInterfaceItemIdentifier("header")
    static let file = NSUserInterfaceItemIdentifier("file")
    static let note = NSUserInterfaceItemIdentifier("note")

    private let chevron = NSImageView()
    /// The text's ink at rest; dimmed rows take `ink3`.
    private var tone: Token = .ink2
    /// A folder that holds the open note.
    private var onPath = false

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
        chevron.contentTintColor = Chrome.color(onPath ? .ink : .ink2)
        if identifier == Self.header {
            textField?.textColor = Chrome.color(.ink2)
            return
        }
        textField?.textColor = Chrome.color(selected || onPath ? .ink : tone)
    }

    /// A file or folder; one that has `gone` from disk, one .gitignore hides, and any file Dewline doesn't edit show
    /// dimmed. A folder `onPath` holds the open note.
    func show(_ entry: FolderEntry, gone: Bool, expanded: Bool, onPath: Bool) {
        chevron.image = (expanded ? Glyph.disclosed : Glyph.disclosure).image
        chevron.isHidden = !entry.isFolder
        textField?.stringValue = entry.url.lastPathComponent
        tone = gone || entry.isIgnored || !(entry.isFolder || entry.isMarkdown || isAgentFile(entry.url)) ? .ink3 : .ink2
        self.onPath = onPath
        toolTip = gone ? "Moved or deleted" : nil
        setAccessibilityLabel(entry.url.lastPathComponent)
        setAccessibilityValue(onPath ? "Holds the open note" : nil)
        paint()
    }

    func show(_ title: String) {
        textField?.stringValue = title
        paint()
    }
}
