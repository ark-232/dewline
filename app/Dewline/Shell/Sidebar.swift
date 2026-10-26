import AppKit
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
        case heading(Heading)
        /// The last row of a folder: what its .gitignore hid.
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
}

/// Pinned, Recents, and the folder tree with the open file's outline under its row; a window with
/// no folder shows the outline as its own section.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var open: (URL, _ newTab: Bool) -> Void = { _, _ in }
    var jump: (Heading) -> Void = { _ in }

    private let folder: Folder?
    private let outlineView = SidebarOutlineView()
    private let pinned = SidebarNode(.section("Pinned"))
    private let recents = SidebarNode(.section("Recents"))
    private let outlineSection = SidebarNode(.section("Outline"), children: [])
    private let tree: SidebarNode?
    private var expandedOnce: Set<ObjectIdentifier> = []
    /// The open file's row in the tree.
    private var fileNode: SidebarNode?
    private var headings: [Heading] = []
    private var showsAllHeadings = false
    /// The location of the heading whose section is at the top of the page.
    private var section: Int?
    private var watch: FolderWatch?

    init(folder: Folder?) {
        self.folder = folder
        tree = folder.map { folder in
            let listing = folder.children(of: folder.url)
            let rows = listing.entries.map { SidebarNode(.entry($0)) }
            return SidebarNode(
                .section(FileManager.default.displayName(atPath: folder.url.path), branch: gitBranch(at: folder.url)),
                children: rows + (listing.ignored.isEmpty ? [] : [SidebarNode(.ignored(listing.ignored))])
            )
        }
        super.init(nibName: nil, bundle: nil)
        watch = folder.map { folder in FolderWatch(folder.url) { [weak self] in self?.filesChanged($0) } }
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
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
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
            default:
                return false
            }
            return true
        }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: Library.changed, object: nil)
        libraryChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    /// Shows `url` as the open file: reveals and selects its row and lists its headings.
    func show(_ url: URL?, text: String) {
        fileNode?.children = nil
        fileNode = url.flatMap(treeNode(for:))
        showsAllHeadings = false
        section = nil
        updateOutline(text)
        if let fileNode {
            outlineView.expandItem(fileNode)
            let row = outlineView.row(forItem: fileNode)
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    func updateOutline(_ text: String) {
        headings = outline(of: text)
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

    private var sections: [SidebarNode] {
        let shortcuts = [pinned, recents].filter { !($0.children ?? []).isEmpty }
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

    /// Lists again each loaded folder FSEvents reported, keeping the rows that remain so their expansion holds.
    private func filesChanged(_ folders: [URL]) {
        guard let folder, let tree else { return }
        let changed = Set(folders.map(\.standardizedFileURL.path))
        func visit(_ node: SidebarNode, _ url: URL) {
            guard let children = node.children else { return }
            if changed.contains(url.path) {
                let listing = folder.children(of: url)
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
        let listing = folder.children(of: entry.url)
        let children = listing.entries.map { SidebarNode(.entry($0)) }
        node.children = children
        return children
    }

    @objc private func libraryChanged() {
        pinned.children = Library.pins.map { url in
            SidebarNode(.shortcut(FolderEntry(url: url, isFolder: url.hasDirectoryPath), nil))
        }
        recents.children = Library.recents.prefix(8).map { visit in
            SidebarNode(.shortcut(FolderEntry(url: visit.url, isFolder: false), visit.date))
        }
        reload()
    }

    @objc private func clicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }
        switch node.kind {
        case .entry(let entry) where entry.isMarkdown:
            open(entry.url, false)
        case .shortcut(let entry, _):
            if entry.isFolder {
                (NSApp.delegate as? AppDelegate)?.openFolder(at: entry.url)
            } else {
                open(entry.url, false)
            }
        default:
            break
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode,
            case .entry(let entry) = node.kind
        else { return }
        if entry.isFolder {
            outlineView.isItemExpanded(node) ? outlineView.collapseItem(node) : outlineView.expandItem(node)
        } else if entry.isMarkdown {
            open(entry.url, true)
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }
        let entry: FolderEntry
        switch node.kind {
        case .entry(let row), .shortcut(let row, _): entry = row
        default: return
        }
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
        }
        if entry.isMarkdown {
            add("Open in New Tab", #selector(openInNewTab(_:)))
            menu.addItem(.separator())
        }
        let isPinned = Library.pins.contains(entry.url)
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

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .section = (item as! SidebarNode).kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        switch (item as! SidebarNode).kind {
        case .entry(let entry), .shortcut(let entry, _): entry.isFolder || entry.isMarkdown
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! SidebarNode
        switch node.kind {
        case .section(let title, let branch):
            let cell = cell(SidebarCell.header)
            cell.show(title, branch: branch)
            return cell
        case .entry(let entry):
            let cell = cell(SidebarCell.file)
            cell.show(entry, detail: nil, gone: false)
            return cell
        case .shortcut(let entry, let date):
            let cell = cell(SidebarCell.file)
            cell.show(entry, detail: date.map { shortDate($0) }, gone: !FileManager.default.fileExists(atPath: entry.url.path))
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
            cell.textField?.stringValue = names.count > 2
                ? "\(names.count) items hidden by .gitignore"
                : names.joined(separator: ", ") + " hidden by .gitignore"
            cell.textField?.textColor = .tertiaryLabelColor
            cell.toolTip = names.joined(separator: "\n")
            return cell
        case .more(let count):
            let cell = cell(SidebarCell.note)
            cell.textField?.stringValue = "Show all \(count)"
            cell.textField?.textColor = .controlAccentColor
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
        default: 26
        }
    }

    private func cell(_ identifier: NSUserInterfaceItemIdentifier) -> SidebarCell {
        outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell ?? SidebarCell(identifier)
    }
}

/// Headings and Show All act on mouse down and never take the selection, which stays on the open file.
private final class SidebarOutlineView: NSOutlineView {
    var clickedWithoutSelecting: (SidebarNode) -> Bool = { _ in false }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if let node = item(atRow: row) as? SidebarNode, clickedWithoutSelecting(node) { return }
        super.mouseDown(with: event)
    }
}

/// One sidebar row: a section header, a file, a heading with a dot leader to its line, or a note.
private final class SidebarCell: NSTableCellView {
    static let header = NSUserInterfaceItemIdentifier("header")
    static let file = NSUserInterfaceItemIdentifier("file")
    static let heading = NSUserInterfaceItemIdentifier("heading")
    static let note = NSUserInterfaceItemIdentifier("note")

    private let detail = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint?

    init(_ identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        addSubview(label)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .tertiaryLabelColor
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(detail)
        var constraints = [
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ]
        if identifier != Self.header {
            constraints.append(detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4))
        }
        switch identifier {
        case Self.header:
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 11)
            let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch")!)
            icon.symbolConfiguration = .init(pointSize: 9, weight: .regular)
            icon.contentTintColor = .tertiaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            imageView = icon
            addSubview(icon)
            constraints += [
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                detail.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            ]
        case Self.file:
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            imageView = icon
            addSubview(icon)
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -6),
            ]
        case Self.heading:
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            let leader = DotLeader()
            leader.translatesAutoresizingMaskIntoConstraints = false
            addSubview(leader)
            let indent = label.leadingAnchor.constraint(equalTo: leadingAnchor)
            self.indent = indent
            constraints += [
                indent,
                leader.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
                leader.trailingAnchor.constraint(equalTo: detail.leadingAnchor, constant: -4),
                leader.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
                leader.heightAnchor.constraint(equalToConstant: 2),
            ]
        default:
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            constraints += [
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarCell is built in code")
    }

    /// A file or folder; one that has `gone` from disk shows dimmed.
    func show(_ entry: FolderEntry, detail text: String?, gone: Bool) {
        let openable = !gone && (entry.isFolder || entry.isMarkdown)
        let type = UTType(filenameExtension: entry.url.pathExtension)
        let symbol = entry.isFolder ? "folder.fill"
            : entry.isMarkdown ? "doc.text"
            : type?.conforms(to: .image) == true ? "photo"
            : type?.conforms(to: .text) == true ? "doc.plaintext"
            : "doc"
        imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView?.contentTintColor = entry.isFolder ? .controlAccentColor : openable ? .secondaryLabelColor : .quaternaryLabelColor
        textField?.stringValue = entry.url.lastPathComponent
        textField?.textColor = openable ? .labelColor : .tertiaryLabelColor
        toolTip = gone ? "Moved or deleted" : nil
        detail.stringValue = text ?? ""
    }

    func show(_ title: String, branch: String?) {
        textField?.stringValue = title
        imageView?.isHidden = branch == nil
        detail.stringValue = branch ?? ""
    }

    func show(_ heading: Heading, current: Bool) {
        textField?.font = current
            ? NSFont(descriptor: NSFont.systemFont(ofSize: 12).fontDescriptor.withSymbolicTraits(.italic), size: 12)
            : .systemFont(ofSize: 12)
        textField?.stringValue = heading.title
        detail.stringValue = String(heading.line)
        indent?.constant = CGFloat(heading.level - 1) * 10
    }
}

/// Dots from a label to the number it leads to.
final class DotLeader: NSView {
    override var firstBaselineOffsetFromTop: CGFloat { 2 }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        var x = bounds.maxX - 2
        while x >= bounds.minX {
            NSBezierPath(ovalIn: NSRect(x: x, y: 0, width: 1.5, height: 1.5)).fill()
            x -= 4
        }
    }
}
