import AppKit
import MdCore
import UniformTypeIdentifiers

/// A row in the sidebar.
@MainActor
final class SidebarNode {
    enum Kind {
        /// A header; a folder root's names the branch its repository has checked out.
        case section(String, branch: String? = nil)
        /// A file or folder in the open folder's tree.
        case entry(FolderEntry)
        /// A Pinned or Recents row, with the time it was opened.
        case shortcut(FolderEntry, Date?)
        /// A file an agent loads, with its load gauge.
        case agentFile(AgentFile)
        case heading(Heading)
        /// The last row of a folder: what its .gitignore hides.
        case ignored([String])
        /// The row after the first 12 headings that shows the rest.
        case more(Int)
        /// A What Loads Here or Review row.
        case agent(AgentRow)
    }

    let kind: Kind
    /// Nil until a folder first expands.
    var children: [SidebarNode]?

    init(_ kind: Kind, children: [SidebarNode]? = nil) {
        self.kind = kind
        self.children = children
    }
}

/// Pinned, Recents, a folder's Agent Files, and the folder tree with the open file's outline under its row; a window
/// with no folder shows the outline as its own section. A folder's window can show Find in Files in place of them.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var open: (URL, _ newTab: Bool) -> Void = { _, _ in }
    var jump: (Heading) -> Void = { _ in }
    /// Opens a file from Find in Files, at a match when there is one.
    var reveal: (URL, TextMatch?, _ newTab: Bool) -> Void = { _, _, _ in }

    private let folder: Folder?
    private let find: FindInFilesController?
    private let outlineView = SidebarOutlineView()
    private let pinned = SidebarNode(.section("Pinned"))
    private let recents = SidebarNode(.section("Recents"))
    private let outlineSection = SidebarNode(.section("Outline"), children: [])
    private let agentSection = SidebarNode(.section("Agent files"), children: [])
    private var agentScan: Task<Void, Never>?
    private let review = SidebarNode(.section("Review"), children: [])
    private let loads = SidebarNode(.section("What loads here"), children: [])
    /// "differs from AGENTS.md" for the open file's folder's instruction files, by path.
    private var flags: [String: (flag: String, sections: [String])] = [:]
    private var reviewWatch: FolderWatch?
    private let tree: SidebarNode?
    private var expandedOnce: Set<ObjectIdentifier> = []
    /// The open file's row in the tree.
    private var fileNode: SidebarNode?
    private var headings: [Heading] = []
    private var showsAllHeadings = false
    /// The location of the heading whose section is at the top of the page.
    private var section: Int?
    private var watch: FolderWatch?
    private var showsIgnored: Bool

    init(folder: Folder?) {
        self.folder = folder
        find = folder.map(FindInFilesController.init)
        let showsIgnored = Preferences.shared.showsIgnored
        self.showsIgnored = showsIgnored
        tree = folder.map { folder in
            let listing = folder.children(of: folder.url, showingIgnored: showsIgnored)
            let rows = listing.entries.map { SidebarNode(.entry($0)) }
            return SidebarNode(
                .section(FileManager.default.displayName(atPath: folder.url.path), branch: gitBranch(at: folder.url)),
                children: rows + (listing.ignored.isEmpty ? [] : [SidebarNode(.ignored(listing.ignored))])
            )
        }
        super.init(nibName: nil, bundle: nil)
        find?.reveal = { [weak self] url, match, newTab in self?.reveal(url, match, newTab) }
        find?.close = { [weak self] in self?.showFiles() }
        watch = folder.map { folder in
            FolderWatch([folder.url]) { [weak self] folders in
                guard let self else { return }
                let changed = Set(folders.map(\.standardizedFileURL.path))
                relist { changed.contains($0.path) }
                let known = (agentSection.children ?? []).compactMap { node -> AgentFile? in
                    if case .agentFile(let file) = node.kind { return file }
                    return nil
                }
                if AgentFile.mayChange(known, in: folders) { findAgentFiles() }
            }
        }
        findAgentFiles()
        reviewWatch = FolderWatch(ReviewInbox.roots(folder: folder?.url)) { [weak self] folders in
            if folders.contains(where: ReviewInbox.matters) { self?.listReview() }
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
            case .agent(let row):
                if let url = row.url {
                    self?.open(url, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
                }
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
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        let root = SidebarGround(frame: NSRect(x: 0, y: 0, width: 248, height: 600))
        if let find { addChild(find) }
        for content in [scrollView] + (find.map { [$0.view] } ?? []) {
            content.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: root.topAnchor),
                content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        find?.view.isHidden = true
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: Library.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fillUnderReducedTransparency), name: ThemeStore.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(fillUnderReducedTransparency), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        fillUnderReducedTransparency()
        libraryChanged()
        if let folder {
            for path in UserDefaults.standard.stringArray(forKey: "Expanded " + folder.url.path) ?? [] {
                _ = treeNode(for: folder.url.appending(path: path))
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    @objc private func fillUnderReducedTransparency() {
        view.needsDisplay = true
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

    /// Shows `url` as the open file: reveals and selects its row and lists its headings.
    func show(_ url: URL?, headings: [Heading]) {
        listLoads(in: url?.deletingLastPathComponent() ?? folder?.url)
        fileNode?.children = nil
        fileNode = url.flatMap(treeNode(for:))
        showsAllHeadings = false
        section = nil
        updateOutline(headings)
        if let fileNode {
            outlineView.expandItem(fileNode)
            let row = outlineView.row(forItem: fileNode)
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    func updateOutline(_ headings: [Heading]) {
        self.headings = headings
        listHeadings()
    }

    private func listHeadings() {
        var rows = headings.map { SidebarNode(.heading($0)) }
        if rows.count > 12, !showsAllHeadings {
            rows = rows.prefix(12) + [SidebarNode(.more(rows.count))]
        }
        if let fileNode {
            fileNode.children = rows
        } else {
            outlineSection.children = rows
        }
        reload()
    }

    /// Sets in italic the heading whose section holds `location`.
    func markSection(at location: Int) {
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

    /// What Loads Here for `directory`.
    private func listLoads(in directory: URL?) {
        loads.children = directory.map { whatLoadsRows(in: $0, root: folder?.url).map { SidebarNode(.agent($0)) } } ?? []
    }

    private func listReview() {
        review.children = ReviewInbox.rows(folder: folder?.url).map { SidebarNode(.agent($0)) }
        reload()
    }

    private var sections: [SidebarNode] {
        let shortcuts = [pinned, recents, agentSection, review, loads].filter { !($0.children ?? []).isEmpty }
        if let tree { return shortcuts + [tree] }
        return shortcuts + (outlineSection.children!.isEmpty ? [] : [outlineSection])
    }

    private func reload() {
        let selected = outlineView.item(atRow: outlineView.selectedRow) as AnyObject?
        outlineView.reloadData()
        for section in sections where expandedOnce.insert(ObjectIdentifier(section)).inserted {
            outlineView.expandItem(section)
        }
        if let selected, outlineView.row(forItem: selected) >= 0 {
            outlineView.selectRowIndexes([outlineView.row(forItem: selected)], byExtendingSelection: false)
        }
    }

    /// The tree row for `url`, expanding the folders above it.
    private func treeNode(for url: URL) -> SidebarNode? {
        guard let tree, let path = folder?.relativePath(of: url) else { return nil }
        outlineView.expandItem(tree)
        var node = tree
        for name in path.split(separator: "/") {
            guard let child = children(of: node).first(where: { child in
                if case .entry(let entry) = child.kind { return entry.url.lastPathComponent == name }
                return false
            }) else { return nil }
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
    }

    private func children(of node: SidebarNode) -> [SidebarNode] {
        if let children = node.children { return children }
        guard case .entry(let entry) = node.kind, entry.isFolder, let folder else { return [] }
        let listing = folder.children(of: entry.url, showingIgnored: showsIgnored)
        let children = listing.entries.map { SidebarNode(.entry($0)) }
        node.children = children
        return children
    }

    /// Lists the folder's agent files again, off the main thread.
    private func findAgentFiles() {
        guard let root = folder?.url else { return }
        agentScan?.cancel()
        agentScan = Task { [weak self] in
            let (files, flags) = await Task.detached(priority: .utility) {
                let files = AgentFile.find(in: root)
                let folders = Set(files.map { $0.url.deletingLastPathComponent() })
                return (files, folders.reduce(into: [String: (flag: String, sections: [String])]()) { flags, folder in
                    flags.merge(divergenceFlags(in: folder)) { first, _ in first }
                })
            }.value
            guard !Task.isCancelled, let self else { return }
            self.flags = flags
            agentSection.children = files.map { SidebarNode(.agentFile($0)) }
            reload()
        }
    }

    @objc private func preferencesChanged() {
        guard Preferences.shared.showsIgnored != showsIgnored else { return }
        showsIgnored = Preferences.shared.showsIgnored
        relist { _ in true }
    }

    @objc private func libraryChanged() {
        pinned.children = Library.pins.map { url in
            SidebarNode(.shortcut(FolderEntry(url: url, isFolder: url.hasDirectoryPath), nil))
        }
        recents.children = Library.recents.prefix(8).map { visit in
            SidebarNode(.shortcut(FolderEntry(url: visit.url, isFolder: false), visit.date))
        }
        listReview()
    }

    /// A click opens in this tab and a Command-click in a new one.
    @objc private func clicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        switch node.kind {
        case .entry(let entry) where entry.isFolder:
            outlineView.isItemExpanded(node) ? outlineView.collapseItem(node) : outlineView.expandItem(node)
        case .entry(let entry) where entry.isMarkdown:
            open(entry.url, newTab)
        case .shortcut(let entry, _):
            if entry.isFolder {
                (NSApp.delegate as? AppDelegate)?.openFolder(at: entry.url)
            } else {
                open(entry.url, newTab)
            }
        case .agentFile(let file):
            open(file.url, newTab)
        default:
            break
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode,
            case .entry(let entry) = node.kind
        else { return }
        if entry.isMarkdown {
            open(entry.url, true)
        }
    }

    /// A folder's chevron turns as it opens and closes.
    private func reloadChevron(_ node: SidebarNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell,
            case .entry(let entry) = node.kind
        else { return }
        cell.show(entry, detail: nil, gone: false, expanded: outlineView.isItemExpanded(node))
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }
        let entry: FolderEntry
        switch node.kind {
        case .entry(let row), .shortcut(let row, _): entry = row
        case .agentFile(let file): entry = FolderEntry(url: file.url, isFolder: false)
        default: return
        }
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
        }
        if entry.isMarkdown || isAgentFile(entry.url) {
            add("Open in New Tab", #selector(openInNewTab(_:)))
            menu.addItem(.separator())
        }
        let isPinned = Library.pins.contains { $0.path == entry.url.path }
        add(isPinned ? "Unpin" : "Pin", isPinned ? #selector(unpin(_:)) : #selector(pin(_:)))
        if case .shortcut(_, .some) = node.kind {
            add("Remove from Recents", #selector(forget(_:)))
        }
        add("Show in Finder", #selector(showInFinder(_:)))
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

    @objc private func forget(_ sender: NSMenuItem) {
        Library.forget(sender.representedObject as! URL)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([sender.representedObject as! URL])
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
        (item as? SidebarNode).map { children(of: $0).count } ?? sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode).map { children(of: $0)[index] } ?? sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let node = item as! SidebarNode
        switch node.kind {
        case .section: return true
        case .entry(let entry): return entry.isFolder || !(node.children ?? []).isEmpty
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        switch (item as! SidebarNode).kind {
        case .entry(let entry), .shortcut(let entry, _): entry.url.lastPathComponent
        case .agentFile(let file): file.url.lastPathComponent
        default: nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .section = (item as! SidebarNode).kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        switch (item as! SidebarNode).kind {
        case .entry(let entry), .shortcut(let entry, _): entry.isFolder || entry.isMarkdown
        case .agentFile: true
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! SidebarNode
        switch node.kind {
        case .section(let title, let branch):
            let cell = cell(SidebarCell.header)
            let counted = node === agentSection || node === review
            cell.show(title, detail: branch ?? (counted ? node.children.map { String($0.count) } : nil))
            return cell
        case .entry(let entry):
            let cell = cell(SidebarCell.file)
            cell.show(entry, detail: nil, gone: false, expanded: outlineView.isItemExpanded(node))
            return cell
        case .agent(let row):
            let cell = cell(SidebarCell.file)
            cell.show(row)
            return cell
        case .shortcut(let entry, let date):
            let cell = cell(SidebarCell.file)
            cell.show(entry, detail: date.map { relativeTime($0) }, gone: !FileManager.default.fileExists(atPath: entry.url.path), expanded: false)
            return cell
        case .agentFile(let file):
            let cell = cell(SidebarCell.agent)
            cell.show(file, path: folder?.relativePath(of: file.url) ?? file.url.lastPathComponent, differs: flags[file.url.path])
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
            cell.textField?.textColor = Chrome.color(.ink3)
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
            cell.textField?.textColor = Chrome.color(.ink2)
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
        case .heading, .more: 22
        case .section: 30
        default: 26
        }
    }

    private func cell(_ identifier: NSUserInterfaceItemIdentifier) -> SidebarCell {
        outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell ?? SidebarCell(identifier)
    }
}

/// The sidebar's ground: the sidebar island in `islandSide`, opaque, with no glass under it.
private final class SidebarGround: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarGround is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        IslandView.paint(layer, fill: .islandSide, in: self)
    }
}

/// Headings and Show All act on mouse down and never take the selection, which stays on the open file. Rows draw
/// their own chevrons, so the system's disclosure triangles are gone, and every level below a section indents 12 pt.
private final class SidebarOutlineView: NSOutlineView {
    var clickedWithoutSelecting: (SidebarNode) -> Bool = { _ in false }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if let node = item(atRow: row) as? SidebarNode, clickedWithoutSelecting(node) { return }
        super.mouseDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        let x = 14 + CGFloat(max(level(forRow: row) - 1, 0)) * indentationPerLevel
        return NSRect(x: x, y: frame.minY, width: max(bounds.width - x - 12, 0), height: frame.height)
    }
}

/// The agent whose instructions a file holds, by its name and folder, for the row's dot.
func agentWriter(of url: URL) -> Writer {
    let name = url.lastPathComponent.lowercased()
    let path = url.path.lowercased()
    if name.hasPrefix("claude") || path.contains("/.claude/") { return .claude }
    if name == "agents.md" || path.contains("/.codex/") { return .codex }
    if name.hasPrefix("gemini") || path.contains("/.gemini/") { return .gemini }
    if name == ".cursorrules" || name.hasSuffix(".mdc") || path.contains("/.cursor/") { return .cursor }
    if name.contains("copilot") { return .copilot }
    return .unknown
}

/// "now", "2m", "3h", "4d", then the date: the sidebar's times, short enough for mono at the row's edge.
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

/// One sidebar row: a section label, a file, a heading with a dot leader to its line, or a note. Every row but a
/// section's keeps a 16 pt leading slot, so names line up: empty for Markdown, a chevron for a folder, a writer's dot
/// for an agent's file, or a two-letter mono tag for any other file. Text is `ink2`; the open file's is `ink`.
private final class SidebarCell: NSTableCellView, ChromeSelectable {
    static let header = NSUserInterfaceItemIdentifier("header")
    static let file = NSUserInterfaceItemIdentifier("file")
    static let heading = NSUserInterfaceItemIdentifier("heading")
    static let note = NSUserInterfaceItemIdentifier("note")
    static let agent = NSUserInterfaceItemIdentifier("agent")

    private let detail = NSTextField(labelWithString: "")
    private let gauge = NSLevelIndicator()
    private let slot = NSView()
    private let chevron = NSImageView()
    private let typeTag = NSTextField(labelWithString: "")
    private let dot = Dot(diameter: 6)
    private var indent: NSLayoutConstraint?
    /// The text's ink at rest; dimmed rows take `ink3`.
    private var tone: Token = .ink2
    private var current = false
    /// An agent's name in What Loads Here, set as a section label.
    private var subhead = false

    var selected = false {
        didSet { paint() }
    }

    init(_ identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = Chrome.label
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        addSubview(label)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = Chrome.mono(10.5)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(detail)
        slot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slot)
        chevron.image = Glyph.disclosure.image
        typeTag.font = Chrome.mono(9.5)
        for view in [chevron, typeTag, dot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            slot.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            ])
        }
        var constraints = [
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            slot.leadingAnchor.constraint(equalTo: leadingAnchor),
            slot.centerYAnchor.constraint(equalTo: centerYAnchor),
            slot.widthAnchor.constraint(equalToConstant: 16),
            slot.heightAnchor.constraint(equalToConstant: 16),
        ]
        switch identifier {
        case Self.header:
            constraints += [
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -8),
            ]
        case Self.file:
            constraints += [
                label.leadingAnchor.constraint(equalTo: slot.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -6),
            ]
        case Self.agent:
            label.lineBreakMode = .byTruncatingHead
            // Secondary ink below 80% of the limit, orange from there, red at the limit, where the agent cuts the file.
            gauge.levelIndicatorStyle = .continuousCapacity
            gauge.minValue = 0
            gauge.maxValue = 1
            gauge.warningValue = 0.8
            gauge.criticalValue = 1
            gauge.fillColor = Chrome.color(.ink3)
            gauge.warningFillColor = .systemOrange
            gauge.criticalFillColor = .systemRed
            gauge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(gauge)
            constraints += [
                label.leadingAnchor.constraint(equalTo: slot.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: gauge.leadingAnchor, constant: -6),
                gauge.trailingAnchor.constraint(equalTo: detail.leadingAnchor, constant: -6),
                gauge.centerYAnchor.constraint(equalTo: centerYAnchor),
                gauge.widthAnchor.constraint(equalToConstant: 24),
                gauge.heightAnchor.constraint(equalToConstant: 4),
            ]
        case Self.heading:
            label.font = Chrome.small
            let leader = DotLeader()
            leader.translatesAutoresizingMaskIntoConstraints = false
            addSubview(leader)
            let indent = label.leadingAnchor.constraint(equalTo: slot.trailingAnchor, constant: 6)
            self.indent = indent
            constraints += [
                indent,
                leader.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
                leader.trailingAnchor.constraint(equalTo: detail.leadingAnchor, constant: -4),
                leader.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
                leader.heightAnchor.constraint(equalToConstant: 2),
            ]
        default:
            label.font = Chrome.brand(11.5, weight: 450, opticalSize: 12)
            tone = .ink3
            constraints += [
                label.leadingAnchor.constraint(equalTo: slot.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            ]
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
        detail.textColor = Chrome.color(.ink3)
        chevron.contentTintColor = Chrome.color(.ink3)
        typeTag.textColor = Chrome.color(.ink3)
        guard identifier != Self.header, !subhead else { return }
        if identifier == Self.file || identifier == Self.agent {
            textField?.font = selected ? Chrome.labelActive : Chrome.label
        }
        if identifier == Self.heading {
            textField?.font = current ? Chrome.brand(12, weight: 560, opticalSize: 12) : Chrome.small
        }
        textField?.textColor = Chrome.color(selected || current ? .ink : tone)
    }

    private func fill(slot kind: (chevron: NSImage?, tag: String?, dot: NSColor?)) {
        chevron.image = kind.chevron
        chevron.isHidden = kind.chevron == nil
        typeTag.stringValue = kind.tag ?? ""
        typeTag.isHidden = kind.tag == nil
        dot.color = kind.dot
        dot.isHidden = kind.dot == nil
    }

    /// A file or folder; one that has `gone` from disk shows dimmed.
    func show(_ entry: FolderEntry, detail text: String?, gone: Bool, expanded: Bool) {
        subhead = false
        let dim = gone || entry.isIgnored || !(entry.isFolder || entry.isMarkdown)
        let ext = entry.url.pathExtension.lowercased()
        let agent = isAgentFile(entry.url)
        fill(slot: (
            entry.isFolder ? (expanded ? Glyph.disclosed : Glyph.disclosure).image : nil,
            !entry.isFolder && !entry.isMarkdown && !agent && !ext.isEmpty ? String(ext.prefix(2)) : nil,
            agent ? ThemeStore.shared.writerColor(agentWriter(of: entry.url)) : nil
        ))
        textField?.stringValue = entry.url.lastPathComponent
        tone = dim ? .ink3 : .ink2
        toolTip = gone ? "Moved or deleted" : nil
        detail.stringValue = text ?? ""
        paint()
    }

    /// An agent file at `path` in its folder, with its agent's dot, its load gauge when its agent documents a limit,
    /// and dim after its path the sibling instruction file it `differs` from.
    func show(_ file: AgentFile, path: String, differs: (flag: String, sections: [String])?) {
        subhead = false
        fill(slot: (nil, nil, ThemeStore.shared.writerColor(agentWriter(of: file.url))))
        let title = NSMutableAttributedString(string: path)
        if let differs {
            title.append(NSAttributedString(string: "  " + differs.flag, attributes: [.font: Chrome.brand(11.5), .foregroundColor: Chrome.color(.ink3)]))
        }
        textField?.attributedStringValue = title
        tone = .ink2
        detail.stringValue = file.tokenLabel
        gauge.isHidden = file.load == nil
        gauge.doubleValue = min(file.load ?? 0, 1)
        let words = [file.gaugeText(date: agentFilesDate)] + (differs.map { ["It \($0.flag) in " + $0.sections.joined(separator: ", ") + "."] } ?? [])
        toolTip = ([path] + words).joined(separator: "\n")
        setAccessibilityLabel(([path] + words).joined(separator: ". "))
        paint()
        if let differs { textField?.attributedStringValue = title.withFlagColored(differs.flag) }
    }

    /// An agent's name as a small label, or one of its files with any divergence flag dim after its name.
    func show(_ row: AgentRow) {
        fill(slot: (nil, nil, row.url.map { ThemeStore.shared.writerColor(agentWriter(of: $0)) }))
        subhead = row.url == nil
        if row.url == nil {
            textField?.attributedStringValue = Chrome.sectionTitle(row.title, color: Chrome.color(.ink3))
            tone = .ink3
        } else {
            let title = NSMutableAttributedString(string: row.title, attributes: [.font: Chrome.label])
            if let flag = row.flag {
                title.append(NSAttributedString(string: "  " + flag, attributes: [.font: Chrome.brand(11.5)]))
            }
            textField?.attributedStringValue = title
            tone = .ink2
        }
        toolTip = row.tip
        detail.stringValue = row.detail
        paint()
        if let flag = row.flag, let title = textField?.attributedStringValue { textField?.attributedStringValue = title.withFlagColored(flag) }
    }

    /// A section's label, sentence case, with its count or branch in mono at the right edge.
    func show(_ title: String, detail text: String?) {
        textField?.attributedStringValue = Chrome.sectionTitle(title, color: Chrome.color(.ink3))
        detail.stringValue = text ?? ""
        paint()
    }

    func show(_ heading: Heading, current: Bool) {
        self.current = current
        textField?.stringValue = heading.title
        detail.stringValue = String(heading.line)
        indent?.constant = 6 + CGFloat(heading.level - 1) * 10
        tone = .ink3
        paint()
    }
}

@MainActor
private extension NSAttributedString {
    /// The text with `flag`, at its end, in `ink3`.
    func withFlagColored(_ flag: String) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: self)
        let range = (string as NSString).range(of: flag, options: .backwards)
        if range.location != NSNotFound { copy.addAttribute(.foregroundColor, value: Chrome.color(.ink3), range: range) }
        return copy
    }
}

/// Dots from a label to the number it leads to.
final class DotLeader: NSView {
    override var firstBaselineOffsetFromTop: CGFloat { 2 }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.color(.hairline).setFill()
        var x = bounds.maxX - 2
        while x >= bounds.minX {
            NSBezierPath(ovalIn: NSRect(x: x, y: 0, width: 1.5, height: 1.5)).fill()
            x -= 4
        }
    }
}
