import AppKit

/// Quick Open and the command palette: one floating panel over the window in front, in the theme's colors. A query
/// that starts with ">" lists the menu bar's enabled commands with their shortcuts; any other finds Markdown files by
/// name in the window's folder, Recents and Pinned.
final class QuickOpenPanel: NSPanel, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: QuickOpenPanel?

    static func show(commands: Bool) {
        let panel = shared ?? QuickOpenPanel()
        shared = panel
        panel.present(commands: commands)
    }

    private enum Row {
        case file(QuickOpenResult)
        case command(MenuCommand, positions: [Int])
    }

    private static let rowHeight: CGFloat = 40
    private static let visibleRows = 9

    private let field = NSTextField()
    private let icon = NSImageView()
    private let table = QuickOpenTable()
    private let empty = NSTextField(labelWithString: "")
    private let background = PanelBackground()
    private let rules = [PanelRule(), PanelRule()]
    private let footer = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint?

    /// The window in front, which files open in.
    private weak var target: NSWindow?
    /// The key window when the panel opened, which commands run for and the keyboard returns to.
    private weak var returnTo: NSWindow?
    private var folder: Folder?
    private weak var index: FolderIndex?
    private var recents: [String: Date] = [:]
    /// Recent files, then pinned ones.
    private var boosted: [URL] = []
    private var files: [QuickOpenFile] = []
    private var commands: [MenuCommand] = []
    private var rows: [Row] = []
    private var search: Task<Void, Never>?
    private var merging: Task<Void, Never>?
    /// Set when Return comes before the search for the last key finishes: open the first result then, in a new tab
    /// when true.
    private var pendingChoice: Bool?
    /// Counts fades, so one that ends after the panel shows again leaves it up.
    private var fade = 0
    private var fading = false

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 134), styleMask: [.borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        delegate = self
        contentView = content()
        initialFirstResponder = field
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged(_:)), name: FolderIndex.changed, object: nil)
    }

    override var canBecomeKey: Bool { true }

    private func content() -> NSView {
        let root = background
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.setAccessibilityElement(false)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.delegate = self
        let (rule, footerRule) = (rules[0], rules[1])
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = Self.rowHeight
        table.refusesFirstResponder = true
        table.allowsTypeSelect = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        empty.font = .systemFont(ofSize: 13)
        empty.alignment = .center
        footer.font = .systemFont(ofSize: 11)
        for view in [icon, field, rule, scroll, empty, footerRule, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let listHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        self.listHeight = listHeight
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            rule.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            listHeight,
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footerRule.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            footerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            footer.centerYAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: 14),
            footer.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        return root
    }

    // MARK: Showing

    /// Gathers the key window's commands and the files of the window in front, then shows at once with the field
    /// focused.
    private func present(commands showsCommands: Bool) {
        // The menus validate against the window, not the panel.
        if isKeyWindow { returnTo?.makeKey() }
        returnTo = NSApp.keyWindow
        target = NSApp.orderedWindows.first { $0.windowController is MainWindowController } ?? returnTo
        let controller = target?.windowController as? MainWindowController
        folder = controller?.folder
        index = controller?.index
        let isFile = { (url: URL) in FolderEntry(url: url, isFolder: false).isMarkdown && FileManager.default.fileExists(atPath: url.path) }
        let visits = Library.recents.filter { isFile($0.url) }
        recents = Dictionary(visits.map { ($0.url.path, $0.date) }) { first, _ in first }
        boosted = visits.map(\.url) + Library.pins.filter(isFile)
        commands = NSApp.mainMenu.map { MenuCommand.all(in: $0, excluding: #selector(AppDelegate.showCommandPalette(_:))) } ?? []

        // Showing again during the fade stops it.
        fade += 1
        fading = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
        let theme = ThemeStore.shared
        for view in [background] + rules {
            view.needsDisplay = true
        }
        field.textColor = theme.color(.ink)
        field.placeholderAttributedString = NSAttributedString(string: "Open a file by name", attributes: [
            .font: NSFont.systemFont(ofSize: 20), .foregroundColor: theme.color(.ink2),
        ])
        footer.textColor = theme.color(.ink2)
        empty.textColor = theme.color(.ink2)
        icon.contentTintColor = theme.color(.ink2)
        field.stringValue = showsCommands ? ">" : ""
        pendingChoice = nil
        merging?.cancel()
        files = QuickOpen.merge([], boosted: boosted, in: folder)
        if let indexed = index?.files { merge(indexed) }
        refresh()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = theme.color(.accent)
            editor.selectedTextAttributes = [.backgroundColor: theme.color(.selection)]
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    /// Recents and pins merged into the folder's files off the main thread; searches wait for it.
    private func merge(_ indexed: [QuickOpenFile]) {
        merging?.cancel()
        let folder = folder
        let boosted = boosted
        merging = Task { [weak self] in
            let merged = await Self.merged(indexed, boosted: boosted, in: folder)
            guard let self, !Task.isCancelled else { return }
            files = merged
        }
    }

    private nonisolated static func merged(_ files: [QuickOpenFile], boosted: [URL], in folder: Folder?) async -> [QuickOpenFile] {
        QuickOpen.merge(files, boosted: boosted, in: folder)
    }

    private nonisolated static func ranked(_ query: String, in files: [QuickOpenFile]) async -> [QuickOpenResult]? {
        QuickOpen.rank(query, in: files)
    }

    @objc private func indexChanged(_ notification: Notification) {
        guard isVisible, let index, notification.object as AnyObject === index, let indexed = index.files else { return }
        merge(indexed)
        if !field.stringValue.hasPrefix(">") { refresh() }
    }

    /// Lists what the query finds: commands at once, files off the main thread, each key cancelling the last search.
    private func refresh() {
        search?.cancel()
        search = nil
        let query = field.stringValue
        let showsCommands = query.hasPrefix(">")
        title = showsCommands ? "Command Palette" : "Quick Open"
        field.setAccessibilityLabel(title)
        icon.image = NSImage(systemSymbolName: showsCommands ? "command" : "magnifyingglass", accessibilityDescription: nil)
        footer.stringValue = showsCommands
            ? "↩ Run    Delete > to find files"
            : "↩ Open    ⌘↩ Open in New Tab    Type > for commands"
        if showsCommands {
            show(MenuCommand.rank(String(query.dropFirst()), in: commands).map { .command($0.command, positions: $0.positions) })
        } else if query.allSatisfy(\.isWhitespace) {
            show(QuickOpen.rank("", in: files)?.map(Row.file) ?? [])
        } else {
            search = Task { [weak self, merging] in
                await merging?.value
                guard let files = self?.files, let results = await Self.ranked(query, in: files), !Task.isCancelled else { return }
                self?.search = nil
                self?.show(results.map(Row.file))
            }
        }
    }

    private func show(_ rows: [Row]) {
        self.rows = rows
        table.deselectAll(nil)
        table.reloadData()
        let query = field.stringValue.hasPrefix(">") ? String(field.stringValue.dropFirst()) : field.stringValue
        let quoted = "\u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}"
        if field.stringValue.hasPrefix(">") {
            empty.stringValue = "No commands match \(quoted)."
        } else if !query.allSatisfy(\.isWhitespace) {
            empty.stringValue = index != nil && index?.files == nil ? "Listing files…" : "No files match \(quoted)."
        } else if let folder {
            empty.stringValue = "Type a name to find a file in \(FileManager.default.displayName(atPath: folder.url.path))."
        } else {
            empty.stringValue = "Type a name to find a file you opened or pinned."
        }
        empty.isHidden = !rows.isEmpty
        if rows.isEmpty {
            announce(empty.stringValue)
        } else {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        place()
        if let newTab = pendingChoice {
            pendingChoice = nil
            choose(table.selectedRow, newTab: newTab)
        }
    }

    /// Sizes the panel to its rows, up to nine, and puts its top 18% down the target window, centered across it.
    private func place() {
        let count = CGFloat(min(max(rows.count, 1), Self.visibleRows))
        listHeight?.constant = count * Self.rowHeight
        let height = 94 + count * Self.rowHeight
        let screen = target?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let anchor = target?.frame ?? visible
        var frame = NSRect(x: anchor.midX - 300, y: anchor.maxY - anchor.height * 0.18 - height, width: 600, height: height)
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = max(frame.minY, visible.minY + 8)
        setFrame(frame, display: isVisible)
        invalidateShadow()
    }

    /// Fades out over 120 ms and hands the keyboard back to the window.
    private func dismiss() {
        guard isVisible, !fading else { return }
        fading = true
        fade += 1
        let generation = fade
        search?.cancel()
        search = nil
        if isKeyWindow { returnTo?.makeKeyAndOrderFront(nil) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fade == generation else { return }
                self.fading = false
                self.orderOut(nil)
                self.alphaValue = 1
                self.files = []
                self.commands = []
                self.show([])
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    // MARK: Choosing

    /// Opens the file in the target window's tab, or a new tab, or runs the command as its menu would.
    private func choose(_ row: Int, newTab: Bool) {
        guard rows.indices.contains(row) else { return NSSound.beep() }
        let controller = target?.windowController as? MainWindowController
        dismiss()
        switch rows[row] {
        case .file(let result):
            if let controller {
                controller.window?.makeKeyAndOrderFront(nil)
                controller.open(result.file.url, newTab: newTab)
            } else {
                NSDocumentController.shared.openDocument(withContentsOf: result.file.url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
        case .command(let command, _):
            command.perform()
        }
    }

    @objc private func clicked() {
        choose(table.clickedRow, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), rows.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Opens or runs the selected row, or the first result of a search still running.
    private func chooseSelected(newTab: Bool) {
        if search != nil {
            pendingChoice = newTab
        } else {
            choose(table.selectedRow, newTab: newTab)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            chooseSelected(newTab: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func controlTextDidChange(_ notification: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveUp(_:)): move(-1)
        case #selector(moveDown(_:)): move(1)
        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)): move(-(Self.visibleRows - 1))
        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)): move(Self.visibleRows - 1)
        case #selector(insertNewline(_:)): chooseSelected(newTab: false)
        case #selector(cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        QuickOpenRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: QuickOpenCell.identifier, owner: nil) as? QuickOpenCell ?? QuickOpenCell()
        let theme = ThemeStore.shared
        switch rows[row] {
        case .file(let result):
            let text = result.file.text
            let path = text.string as NSString
            let name = path.substring(from: text.nameStart)
            let folderPath = text.nameStart > 0 ? path.substring(to: text.nameStart - 1) : folder.map { FileManager.default.displayName(atPath: $0.url.path) } ?? ""
            let detail = recents[result.file.url.path].map { shortDate($0) } ?? (result.file.boost != nil ? "Pinned" : "")
            cell.show(
                symbol: "doc.text",
                title: Self.highlighted(name, result.positions, from: text.nameStart, size: 13, color: theme.color(.ink), truncating: .byTruncatingMiddle),
                detail: Self.highlighted(folderPath, text.nameStart > 0 ? result.positions : [], from: 0, size: 11, color: theme.color(.ink2), truncating: .byTruncatingHead),
                trailing: detail
            )
            cell.setAccessibilityLabel([name, folderPath, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        case .command(let command, let positions):
            cell.show(
                symbol: nil,
                title: Self.highlighted(command.item.title, positions, from: 0, size: 13, color: theme.color(.ink)),
                detail: Self.highlighted(command.path, [], from: 0, size: 11, color: theme.color(.ink2)),
                trailing: command.shortcut
            )
            let key = KeyEquivalent(command.item.keyEquivalent, command.item.keyEquivalentModifierMask).spoken
            cell.setAccessibilityLabel([command.item.title, command.path + " menu", key].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, let label = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true)?.accessibilityLabel()
        else { return }
        announce(label)
    }

    /// Tells VoiceOver which row Return would choose, or that nothing matches, since the keyboard stays in the field.
    private func announce(_ label: String) {
        guard isVisible else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: label,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// `text` with the letters at `positions` (offsets into the matched string, which `text` starts `from`) in
    /// semibold ink.
    private static func highlighted(_ text: String, _ positions: [Int], from start: Int, size: CGFloat, color: NSColor,
                                    truncating: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = truncating
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: line,
        ])
        let strong: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: ThemeStore.shared.color(.ink),
        ]
        for position in positions where position >= start && position - start < string.length {
            string.addAttributes(strong, range: NSRange(location: position - start, length: 1))
        }
        return string
    }
}

/// The results list, which never takes the keyboard from the field.
private final class QuickOpenTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// A result: a file's name over its folder, or a command over its menu, with the time, "Pinned" or the shortcut at the
/// right.
private final class QuickOpenCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("result")

    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private var leading: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        for label in [title, detail] {
            label.maximumNumberOfLines = 1
        }
        trailing.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [title, detail] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        for view in [symbol, lines, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading = lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 42)
        self.leading = leading
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 22),
            leading,
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("QuickOpenCell is built in code")
    }

    func show(symbol name: String?, title text: NSAttributedString, detail line: NSAttributedString, trailing value: String) {
        let theme = ThemeStore.shared
        symbol.image = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbol.isHidden = name == nil
        symbol.contentTintColor = theme.color(.ink2)
        leading?.constant = name == nil ? 14 : 42
        title.attributedStringValue = text
        detail.attributedStringValue = line
        detail.isHidden = line.length == 0
        trailing.stringValue = value
        trailing.textColor = theme.color(.ink2)
    }
}

/// The selected result on the theme's selection color, which keeps ink legible on it.
private final class QuickOpenRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        ThemeStore.shared.color(.selection).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// The panel's ground: the theme's paper with a hairline edge, rounded like a window.
private final class PanelBackground: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ThemeStore.shared.color(.paper).cgColor
        layer?.borderColor = ThemeStore.shared.color(.syntax).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
    }
}

/// A hairline between the field, the results and the footer.
private final class PanelRule: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ThemeStore.shared.color(.syntax).cgColor
    }
}
