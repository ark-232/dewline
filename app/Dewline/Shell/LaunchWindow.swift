import AppKit

/// The window shown when nothing is open, 560 by 400: the mark and name with the tagline across from them, one list
/// of recent folders then notes, and New Note, Open and Open Folder along the bottom.
final class LaunchWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static var showsWhenNothingIsOpen: Bool {
        // The test host stays windowless.
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && UserDefaults.standard.object(forKey: "ShowLaunchWindow") as? Bool ?? true
    }

    static let size = NSSize(width: 560, height: 400)

    private struct Row {
        let url: URL
        let isFolder: Bool
        let date: Date
    }

    private let list = LaunchList()
    private let filter = NSSearchField()
    private let empty = NSTextField(labelWithString: "Notes and folders you open show up here.")
    private let name = NSTextField(labelWithString: "Dewline")
    private let tagline = NSTextField(labelWithString: "Notes you can grep.")
    private var rows: [Row] = []
    private var filterHeight: NSLayoutConstraint!

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dewline"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.contentView = content()
        window.initialFirstResponder = list
        window.autorecalculatesKeyViewLoop = true
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Library.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: ThemeStore.didChange, object: nil)
        applyTheme()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("LaunchWindowController is built in code")
    }

    @objc private func applyTheme() {
        name.textColor = Chrome.color(.ink)
        tagline.textColor = Chrome.color(.ink2)
        empty.textColor = Chrome.color(.ink2)
        list.reloadData()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if let window { Updates.shared.windowDidShow(window) }
    }

    private func content() -> NSView {
        let root = PaperView()
        let mark = DewMark(size: NSSize(width: 16.5, height: 17))
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let lockup = NSStackView(views: [mark, name])
        lockup.spacing = 8
        lockup.alignment = .lastBaseline
        lockup.setAccessibilityElement(true)
        lockup.setAccessibilityLabel("Dewline")
        tagline.font = Chrome.label
        filter.placeholderString = "Filter"
        filter.delegate = self
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        list.headerView = nil
        list.style = .plain
        list.backgroundColor = .clear
        list.intercellSpacing = .zero
        list.allowsTypeSelect = false
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(openSelected)
        list.setAccessibilityLabel("Recent")
        list.onKey = { [weak self] event in self?.handle(event) ?? false }
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        empty.font = Chrome.label
        empty.alignment = .center
        let new = NSButton(title: "New Note", target: nil, action: #selector(AppDelegate.newDocument(_:)))
        new.keyEquivalent = "\r"
        let open = NSButton(title: "Open…", target: nil, action: #selector(NSDocumentController.openDocument(_:)))
        let folder = NSButton(title: "Open Folder…", target: nil, action: #selector(AppDelegate.openFolder(_:)))
        let buttons = NSStackView(views: [folder, open, new])
        buttons.spacing = 8
        for view in [lockup, tagline, filter, scroll, empty, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        filterHeight = filter.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.size.width),
            root.heightAnchor.constraint(equalToConstant: Self.size.height),
            lockup.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            lockup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            tagline.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            tagline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            filter.topAnchor.constraint(equalTo: lockup.bottomAnchor, constant: 20),
            filter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        return root
    }

    /// Recent folders, then recent notes, each newest first, that match the filter.
    @objc private func reload() {
        let query = filter.stringValue
        func matches(_ visit: Library.Visit) -> Bool {
            query.isEmpty || visit.url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
        let folders = Library.recentFolders.map { Row(url: $0.url, isFolder: true, date: $0.date) }
        let notes = Library.recents.map { Row(url: $0.url, isFolder: false, date: $0.date) }
        let all = folders + notes
        rows = all.filter { matches(Library.Visit(url: $0.url, date: $0.date)) }
        // The filter shows once there are more than 8 rows to look through.
        let filters = all.count > 8
        filter.isHidden = !filters
        filterHeight.isActive = !filters
        list.reloadData()
        if !rows.isEmpty { list.selectRowIndexes([0], byExtendingSelection: false) }
        empty.stringValue = query.isEmpty ? "Notes and folders you open show up here." : "Nothing matches \u{201C}\(query)\u{201D}."
        empty.isHidden = !rows.isEmpty
    }

    @objc private func openSelected() {
        guard rows.indices.contains(list.selectedRow) else { return }
        let row = rows[list.selectedRow]
        if row.isFolder {
            (NSApp.delegate as? AppDelegate)?.openFolder(at: row.url)
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: row.url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    /// Return opens, Delete forgets a recent note, and typing goes to the filter.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            openSelected()
            return true
        case 51, 117:
            guard rows.indices.contains(list.selectedRow), !rows[list.selectedRow].isFolder else { return false }
            Library.forget(rows[list.selectedRow].url)
            return true
        default:
            guard !filter.isHidden, event.specialKey == nil, event.modifierFlags.isDisjoint(with: [.command, .control]),
                let characters = event.characters, !characters.isEmpty,
                characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return false }
            window?.makeFirstResponder(filter)
            filter.currentEditor()?.insertText(characters)
            return true
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    // MARK: List

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        36
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        StationRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: RecentCell.identifier, owner: nil) as? RecentCell ?? RecentCell()
        let item = rows[row]
        cell.show(item.url, isFolder: item.isFolder, date: item.date)
        return cell
    }
}

/// The recents list, passing keys it doesn't use to the launch window.
private final class LaunchList: NSTableView {
    var onKey: (NSEvent) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }
}

/// A recent folder or note: its name, the folder it is in, and when it was last open.
private final class RecentCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("recent")

    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = Chrome.label
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        folder.font = Chrome.label
        folder.lineBreakMode = .byTruncatingTail
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = Chrome.status
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        textField = name
        for view in [icon, name, folder, time] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            folder.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            folder.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -12),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("RecentCell is built in code")
    }

    func show(_ url: URL, isFolder: Bool, date: Date) {
        let exists = FileManager.default.fileExists(atPath: url.path)
        name.stringValue = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        folder.stringValue = isFolder ? "" : url.deletingLastPathComponent().lastPathComponent
        time.stringValue = relativeTime(date)
        icon.image = NSImage(systemSymbolName: isFolder ? "folder" : "doc.text", accessibilityDescription: isFolder ? "Folder" : "Note")
        name.textColor = Chrome.color(exists ? .ink : .ink3)
        folder.textColor = Chrome.color(.ink2)
        time.textColor = Chrome.color(.ink2)
        icon.contentTintColor = Chrome.color(.ink2)
        toolTip = exists ? (url.path as NSString).abbreviatingWithTildeInPath : "Moved or deleted"
        setAccessibilityLabel([name.stringValue, folder.stringValue, time.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
