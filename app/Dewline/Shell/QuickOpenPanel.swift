import AppKit

/// The palette: one floating panel over the window in front, in the theme's colors. Shift-Cmd-P opens it on ">",
/// the menu bar's enabled commands and the settings; Shift-Cmd-O opens it empty, which finds Markdown files by name in
/// the window's folder, Recents and Pinned. "@" lists the open file's headings, ":" goes to a line, "#" finds headings
/// across the folder and "?" lists these prefixes; "notes@intro" and "notes:42" reach into a file.
final class QuickOpenPanel: NSPanel, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: QuickOpenPanel?

    /// Opens the palette on commands or files; the same shortcut again closes it, the other switches.
    static func show(commands: Bool) {
        let panel = shared ?? QuickOpenPanel()
        shared = panel
        if panel.isVisible, panel.isKeyWindow {
            if panel.choices != nil || panel.field.stringValue.hasPrefix(">") == commands { return panel.dismiss() }
            panel.field.stringValue = commands ? ">" : ""
            panel.refresh()
            return
        }
        panel.present(commands: commands)
    }

    private enum Mode {
        case files(String)
        case fileLine(String, Int?)
        case fileHeadings(String, String)
        case commands(String)
        case headings(String)
        case line(String)
        case folderHeadings(String)
        case help
    }

    private enum Row {
        case header(String)
        case file(QuickOpenResult, line: Int?)
        case command(PaletteHit)
        case heading(PaletteHeading, positions: [Int])
        case line(Int)
        case prefix(String, title: String, symbol: String)
        case choice(Int, positions: [Int])

        var selectable: Bool {
            if case .header = self { return false }
            return true
        }
    }

    private static let rowHeight: CGFloat = 32
    private static let width: CGFloat = 640
    /// Eight rows and half of the ninth show, so a longer list reads as one that scrolls.
    private static let visibleRows: CGFloat = 8.5
    private static let prefixes: [(String, String, String)] = [
        (">", "Commands and settings", "command"),
        ("@", "Headings in this file", "list.bullet.indent"),
        (":", "Go to a line", "arrow.right.to.line"),
        ("#", "Headings in the folder", "number"),
        ("", "Files by name (add @ or : to reach into one)", "doc.text"),
    ]
    /// Commands offered before you type, by action, after the agent changes and the recent ones.
    private static let suggested = [
        "newWindowForTab:", "openFolder:", "findInFiles:", "toggleSource:", "toggleFocusMode:", "toggleTypewriterMode:",
        "goToLine:", "showSettings:",
    ]

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
    private var commands: [PaletteCommand] = []
    private var frecency: [String: Double] = [:]
    private var rows: [Row] = []
    private var search: Task<Void, Never>?
    private var merging: Task<Void, Never>?
    /// The folder's headings for "#", read once per showing.
    private var headingScan: Task<[PaletteHeading], Never>?
    /// Set when Return comes before the search for the last key finishes: open the first result then, in a new tab
    /// when true.
    private var pendingChoice: Bool?
    /// A setting's second level, previewing the selected value, and the query and command it came from.
    private var choices: PaletteChoices?
    private var choicesFrom: (query: String, id: String)?
    private var previewed: Int?
    private var closing = false
    /// Where the mouse last moved the selection, so rows scrolling under a still pointer leave it alone.
    private var pointer: NSPoint?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 134), styleMask: [.borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        delegate = self
        contentView = content()
        initialFirstResponder = field
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged(_:)), name: FolderIndex.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeStore.didChange, object: nil)
    }

    override var canBecomeKey: Bool { true }

    private func content() -> NSView {
        let root = background
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.setAccessibilityElement(false)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
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
        table.hovered = { [weak self] row, point in self?.hover(row, at: point) }
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
        footer.lineBreakMode = .byTruncatingTail
        for view in [icon, field, rule, scroll, empty, footerRule, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let listHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        self.listHeight = listHeight
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            rule.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
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
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            footer.centerYAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: 14),
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
        let menu = NSApp.mainMenu.map { MenuCommand.all(in: $0, excluding: #selector(AppDelegate.showCommandPalette(_:))) } ?? []
        let dark = (target ?? returnTo)?.effectiveAppearance.isDark ?? NSApp.effectiveAppearance.isDark
        // Smart Punctuation is a setting row, with its value.
        commands = menu.filter { $0.item.action != #selector(EditorTextView.toggleSmartPunctuation(_:)) }.map(PaletteCommand.init)
            + PaletteCommand.settings(dark: dark)
        frecency = PaletteHistory.frecency()
        choices = nil
        choicesFrom = nil
        previewed = nil
        pointer = nil
        headingScan = nil

        field.stringValue = showsCommands ? ">" : ""
        pendingChoice = nil
        merging?.cancel()
        files = QuickOpen.merge([], boosted: boosted, in: folder)
        if let indexed = index?.files { merge(indexed) }
        recolor()
        refresh()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        placeCaret()
    }

    private func placeCaret() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let theme = ThemeStore.shared
        editor.insertionPointColor = theme.color(.accent)
        editor.selectedTextAttributes = [.backgroundColor: theme.color(.selection)]
        editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    /// The theme's colors on the panel's own views; rows take them as they draw.
    private func recolor() {
        let theme = ThemeStore.shared
        for view in [background] + rules {
            view.needsDisplay = true
        }
        field.textColor = theme.color(.ink)
        footer.textColor = theme.color(.ink2)
        empty.textColor = theme.color(.ink2)
        icon.contentTintColor = theme.color(.ink2)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = theme.color(.accent)
            editor.selectedTextAttributes = [.backgroundColor: theme.color(.selection)]
        }
    }

    /// A theme previewed from the panel recolors it at once.
    @objc private func themeChanged() {
        guard isVisible else { return }
        recolor()
        placeholder(field.placeholderString ?? "")
        if !rows.isEmpty { table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [0]) }
        table.enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
    }

    private func placeholder(_ text: String) {
        field.placeholderString = text
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: ThemeStore.shared.color(.ink2),
        ])
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

    /// The files matching `query`, or failing that matching it with two neighboring letters swapped.
    private nonisolated static func ranked(_ query: String, in files: [QuickOpenFile]) async -> [QuickOpenResult]? {
        guard let results = QuickOpen.rank(query, in: files) else { return nil }
        guard results.isEmpty else { return results }
        for swapped in FuzzyText.transpositions(of: query) {
            guard let results = QuickOpen.rank(swapped, in: files) else { return nil }
            if !results.isEmpty { return results }
        }
        return []
    }

    private nonisolated static func ranked(_ query: String, in headings: [PaletteHeading]) async -> [(heading: PaletteHeading, positions: [Int])]? {
        PaletteHeading.rank(query, in: headings)
    }

    @objc private func indexChanged(_ notification: Notification) {
        guard isVisible, let index, notification.object as AnyObject === index, let indexed = index.files else { return }
        merge(indexed)
        if choices == nil, case .files = Self.mode(of: field.stringValue) { refresh() }
    }

    private static func mode(of query: String) -> Mode {
        guard let first = query.first else { return .files("") }
        let rest = String(query.dropFirst())
        switch first {
        case ">": return .commands(rest)
        case "@": return .headings(rest)
        case ":": return .line(rest)
        case "#": return .folderHeadings(rest)
        case "?": return .help
        default: break
        }
        if let at = query.lastIndex(of: "@") {
            return .fileHeadings(String(query[..<at]), String(query[query.index(after: at)...]))
        }
        if let colon = query.lastIndex(of: ":") {
            let number = query[query.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if number.allSatisfy(\.isNumber) { return .fileLine(String(query[..<colon]), Int(number)) }
        }
        return .files(query)
    }

    /// Lists what the query finds: commands, headings of the open file and lines at once; files and the folder's
    /// headings off the main thread, each key cancelling the last search.
    private func refresh() {
        search?.cancel()
        search = nil
        let query = field.stringValue
        if let choices {
            chrome(choices.title, symbol: choices.symbol, footer: "↑↓ Preview    ↩ Keep    ⎋ Restore")
            placeholder(choices.title)
            let letters = FuzzyText.query(query)
            show(choices.names.enumerated().compactMap { index, name -> Row? in
                if letters.isEmpty { return .choice(index, positions: []) }
                return FuzzyText(name).forgivingMatch(letters).map { .choice(index, positions: $0.positions) }
            })
            return
        }
        switch Self.mode(of: query) {
        case .commands(let text):
            chrome("Command Palette", symbol: "command", footer: "↩ Run    ⇥ Open a setting    ⎋ Clear    Delete > to find files")
            show(commandRows(text))
        case .help:
            chrome("Palette Prefixes", symbol: "questionmark.circle", footer: "↩ Use the prefix")
            show(Self.prefixes.map { .prefix($0.0, title: $0.1, symbol: $0.2) })
        case .headings(let text):
            chrome("Go to Heading", symbol: "list.bullet.indent", footer: "↩ Go to the heading    Delete @ to find files")
            let headings = currentHeadings()
            show(PaletteHeading.rank(text, in: headings)?.map { .heading($0.heading, positions: $0.positions) } ?? [])
        case .line(let text):
            chrome("Go to Line", symbol: "arrow.right.to.line", footer: "↩ Go to the line    Delete : to find files")
            let number = Int(text.trimmingCharacters(in: .whitespaces))
            show(number.map { [.line($0)] } ?? [])
        case .folderHeadings(let text):
            chrome("Headings in Folder", symbol: "number", footer: "↩ Go to the heading    ⌘↩ In a new tab")
            guard let urls = index?.files?.map(\.url) else { return show([]) }
            let folder = folder
            let scan = headingScan ?? Task { await PaletteHeading.scan(urls, in: folder) }
            headingScan = scan
            run { _ in
                guard let ranked = await Self.ranked(text, in: await scan.value) else { return nil }
                return ranked.map { .heading($0.heading, positions: $0.positions) }
            }
        case .files(let text):
            chrome("Quick Open", symbol: "magnifyingglass", footer: "↩ Open    ⌘↩ Open in New Tab    > Commands    ? Help")
            if text.allSatisfy(\.isWhitespace) {
                show(QuickOpen.rank("", in: files)?.map { .file($0, line: nil) } ?? [])
            } else {
                run { panel in await Self.ranked(text, in: panel.files)?.map { .file($0, line: nil) } }
            }
        case .fileLine(let text, let line):
            chrome("Go to Line in File", symbol: "arrow.right.to.line", footer: "↩ Open at the line    ⌘↩ In a new tab")
            run { panel in await Self.ranked(text, in: panel.files)?.map { .file($0, line: line) } }
        case .fileHeadings(let text, let heading):
            chrome("Go to Heading in File", symbol: "list.bullet.indent", footer: "↩ Open at the heading    ⌘↩ In a new tab")
            run { panel in
                guard let top = await Self.ranked(text, in: panel.files)?.first else { return nil }
                let headings = await panel.headings(of: top.file)
                return await Self.ranked(heading, in: headings)?.map { .heading($0.heading, positions: $0.positions) }
            }
        }
    }

    private func chrome(_ name: String, symbol: String, footer hint: String) {
        title = name
        field.setAccessibilityLabel(name)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        footer.stringValue = hint
        if choices == nil { placeholder("Open a file by name, or type ? for more") }
    }

    /// Runs `work` after the files merge, off the keystroke, and shows its rows unless a later key cancelled it.
    private func run(_ work: @escaping @MainActor (QuickOpenPanel) async -> [Row]?) {
        search = Task { [weak self, merging] in
            await merging?.value
            guard let self, !Task.isCancelled, let rows = await work(self), !Task.isCancelled else { return }
            search = nil
            show(rows)
        }
    }

    /// The commands matching `query`; before you type, the agent changes waiting, then the recent and the suggested.
    private func commandRows(_ query: String) -> [Row] {
        func hit(_ command: PaletteCommand) -> Row {
            .command(PaletteHit(command: command, positions: [], alias: nil, aliasPositions: []))
        }
        guard query.allSatisfy(\.isWhitespace) else {
            return PaletteRank.rank(query, in: commands, frecency: frecency).map(Row.command)
        }
        var rows: [Row] = []
        var shown: Set<String> = []
        func group(_ name: String, _ commands: [PaletteCommand]) {
            let fresh = commands.filter { !shown.contains($0.id) }
            guard !fresh.isEmpty else { return }
            rows.append(.header(name))
            rows += fresh.map(hit)
            shown.formUnion(fresh.map(\.id))
        }
        let pending = Review.files(in: target ?? returnTo).reduce(0) { $0 + $1.changes.values.count(where: \.marked) }
        if pending > 0 {
            let actions = [#selector(EditorTextView.keepChange(_:)), #selector(EditorTextView.revertChange(_:)), #selector(ReviewPanel.toggleReview(_:))]
            group("Agent Changes · \(pending) pending", actions.compactMap { action in commands.first { $0.selector == action } })
        }
        group("Recent", PaletteHistory.recent.compactMap { id in commands.first { $0.id == id } })
        let suggested = Self.suggested.compactMap { action in commands.first { $0.selector.map(NSStringFromSelector) == action } }
        group("Suggested", suggested + commands.filter { $0.id == "settings:theme" })
        return rows
    }

    /// The open file's headings, from its outline.
    private func currentHeadings() -> [PaletteHeading] {
        let controller = target?.windowController as? MainWindowController
        guard let textView = controller?.textView else { return [] }
        return outline(of: textView.textStorage!.mutableString, in: textView.styler.map).map {
            PaletteHeading(url: nil, file: "", title: $0.title, level: $0.level, line: $0.line)
        }
    }

    /// A file's headings: from its outline when it is open, else read from the disk.
    private func headings(of file: QuickOpenFile) async -> [PaletteHeading] {
        let name = file.text.string
        if let controller = NSDocumentController.shared.document(for: file.url)?.windowControllers.first as? MainWindowController,
            let textView = controller.textView {
            return outline(of: textView.textStorage!.mutableString, in: textView.styler.map).map {
                PaletteHeading(url: file.url, file: name, title: $0.title, level: $0.level, line: $0.line)
            }
        }
        let url = file.url
        return await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return PaletteHeading.scan(text, url: url, file: name)
        }.value
    }

    private func show(_ rows: [Row]) {
        self.rows = rows
        table.deselectAll(nil)
        table.reloadData()
        empty.stringValue = emptyText()
        empty.isHidden = !rows.isEmpty
        if rows.isEmpty {
            announce(empty.stringValue)
        } else if let first = rows.firstIndex(where: { isCurrentChoice($0) }) ?? rows.firstIndex(where: \.selectable) {
            select(first)
        }
        place()
        if let newTab = pendingChoice {
            pendingChoice = nil
            choose(table.selectedRow, newTab: newTab)
        }
    }

    private func isCurrentChoice(_ row: Row) -> Bool {
        guard let choices, case .choice(let index, _) = row else { return false }
        return index == choices.current
    }

    private func emptyText() -> String {
        if let choices { return "No \(choices.title.lowercased()) matches." }
        switch Self.mode(of: field.stringValue) {
        case .commands(let text): return "No commands match \(Self.quoted(text))."
        case .help: return ""
        case .headings: return target?.windowController is MainWindowController ? "No headings match." : "Open a file to list its headings."
        case .line: return "Type a line number."
        case .folderHeadings: return folder == nil ? "Open a folder to find headings across it." : "No headings match."
        case .fileHeadings: return "No heading matches in that file."
        case .files(let text) where text.allSatisfy(\.isWhitespace):
            if let folder { return "Type a name to find a file in \(FileManager.default.displayName(atPath: folder.url.path))." }
            return "Type a name to find a file you opened or pinned."
        case .files(let text), .fileLine(let text, _):
            return index != nil && index?.files == nil ? "Listing files…" : "No files match \(Self.quoted(text))."
        }
    }

    private static func quoted(_ text: String) -> String {
        "\u{201C}\(text.trimmingCharacters(in: .whitespaces))\u{201D}"
    }

    /// Sizes the panel to its rows, eight and a half at most, and puts its top 20% down the target window, centered
    /// across it.
    private func place() {
        let count = rows.count > 8 ? Self.visibleRows : CGFloat(max(rows.count, 1))
        listHeight?.constant = count * Self.rowHeight
        let height = 90 + count * Self.rowHeight
        let screen = target?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let anchor = target?.frame ?? visible
        var frame = NSRect(x: anchor.midX - Self.width / 2, y: anchor.maxY - anchor.height * 0.2 - height, width: Self.width, height: height)
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = max(frame.minY, visible.minY + 8)
        setFrame(frame, display: isVisible)
        invalidateShadow()
    }

    /// Hides at once and hands the keyboard back to the window; a value being previewed goes back first.
    private func dismiss() {
        guard isVisible, !closing else { return }
        closing = true
        defer { closing = false }
        if let choices { choices.apply(choices.current) }
        choices = nil
        choicesFrom = nil
        search?.cancel()
        search = nil
        headingScan?.cancel()
        headingScan = nil
        if isKeyWindow { returnTo?.makeKeyAndOrderFront(nil) }
        orderOut(nil)
        files = []
        commands = []
        rows = []
        table.reloadData()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    // MARK: Choosing

    /// Opens the file in the target window's tab, or a new tab, runs the command as its menu would, or goes to the
    /// heading or line.
    private func choose(_ row: Int, newTab: Bool) {
        guard rows.indices.contains(row), rows[row].selectable else { return NSSound.beep() }
        let controller = target?.windowController as? MainWindowController
        switch rows[row] {
        case .header: break
        case .command(let hit): run(hit.command)
        case .prefix(let prefix, _, _):
            field.stringValue = prefix
            placeCaret()
            refresh()
        case .choice:
            if let id = choicesFrom?.id { PaletteHistory.ran(id) }
            choices = nil
            dismiss()
        case .file(let result, let line):
            dismiss()
            open(result.file.url, in: controller, newTab: newTab) { tab in
                if let line { tab.textView?.jump(toLine: line) }
            }
        case .heading(let heading, _):
            dismiss()
            let reveal: @MainActor @Sendable (MainWindowController) -> Void = { tab in
                guard let textView = tab.textView else { return }
                let live = outline(of: textView.textStorage!.mutableString, in: textView.styler.map)
                if let found = live.filter({ $0.title == heading.title }).min(by: { abs($0.line - heading.line) < abs($1.line - heading.line) }) {
                    tab.jump(to: found)
                } else {
                    textView.jump(toLine: heading.line)
                }
            }
            if let url = heading.url {
                open(url, in: controller, newTab: newTab, then: reveal)
            } else if let controller {
                reveal(controller)
            }
        case .line(let line):
            dismiss()
            guard let textView = controller?.textView else { return NSSound.beep() }
            controller?.window?.makeFirstResponder(textView)
            textView.jump(toLine: line)
        }
    }

    /// Opens `url` in `controller`'s window, or as a document without one, then hands its tab to `then`.
    private func open(_ url: URL, in controller: MainWindowController?, newTab: Bool,
                      then: @escaping @MainActor @Sendable (MainWindowController) -> Void) {
        guard let controller else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let error { NSApp.presentError(error) }
                if let tab = document?.windowControllers.first as? MainWindowController { then(tab) }
            }
            return
        }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.open(url, newTab: newTab)
        guard let tab = NSDocumentController.shared.document(for: url)?.windowControllers.first as? MainWindowController else { return }
        if let textView = tab.textView { tab.window?.makeFirstResponder(textView) }
        then(tab)
    }

    /// Runs a menu command and shows its shortcut for next time, flips a setting in place, or opens a setting's
    /// values.
    private func run(_ command: PaletteCommand) {
        switch command.action {
        case .menu(let menu):
            PaletteHistory.ran(command.id)
            let window = returnTo ?? target
            dismiss()
            menu.perform()
            if let caps = command.keys?.caps, !caps.isEmpty { ShortcutHint.show(caps, in: window) }
        case .toggle(let toggle):
            PaletteHistory.ran(command.id)
            toggle()
            let row = table.selectedRow
            if rows.indices.contains(row) { table.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
            if let value = command.value?() { announce("\(command.title), \(value)") }
        case .choose(let make):
            enter(make(), from: command.id)
        }
    }

    /// Shows a setting's values with the current one selected.
    private func enter(_ level: PaletteChoices, from id: String) {
        choicesFrom = (field.stringValue, id)
        choices = level
        previewed = level.current
        field.stringValue = ""
        refresh()
        placeCaret()
    }

    /// Back from a setting's values to the query that led there, with the value it had.
    private func leaveChoices() {
        guard let choices, let from = choicesFrom else { return }
        choices.apply(choices.current)
        self.choices = nil
        choicesFrom = nil
        previewed = nil
        field.stringValue = from.query
        refresh()
        placeCaret()
    }

    /// Tab or Right Arrow on a setting with values opens them.
    private func openSelectedLevel() -> Bool {
        guard rows.indices.contains(table.selectedRow), case .command(let hit) = rows[table.selectedRow],
            case .choose(let make) = hit.command.action
        else { return false }
        enter(make(), from: hit.command.id)
        return true
    }

    @objc private func clicked() {
        choose(table.clickedRow, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Moves the selection by `delta` selectable rows, stopping at the ends.
    private func move(_ delta: Int) {
        guard let first = rows.firstIndex(where: \.selectable), let last = rows.lastIndex(where: \.selectable) else { return }
        guard table.selectedRow >= 0 else { return select(first) }
        var row = table.selectedRow
        var steps = abs(delta)
        while steps > 0 {
            var next = row + delta.signum()
            while rows.indices.contains(next), !rows[next].selectable { next += delta.signum() }
            guard rows.indices.contains(next) else { break }
            row = next
            steps -= 1
        }
        select(min(max(row, first), last))
    }

    /// The pointer selects the row under it only when it has moved.
    private func hover(_ row: Int, at point: NSPoint) {
        defer { pointer = point }
        guard let pointer, pointer != point, rows.indices.contains(row), rows[row].selectable, row != table.selectedRow else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
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
        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)): move(-8)
        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)): move(8)
        case #selector(insertNewline(_:)): chooseSelected(newTab: false)
        case #selector(insertTab(_:)): _ = openSelectedLevel()
        case #selector(moveRight(_:)):
            guard textView.selectedRange() == NSRange(location: (textView.string as NSString).length, length: 0), openSelectedLevel()
            else { return false }
        case #selector(cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }

    /// Escape: back from a setting's values, else clears the query down to its prefix, else closes.
    private func cancel() {
        if choices != nil { return leaveChoices() }
        let query = field.stringValue
        let bare = query.first.map { ">@:#?".contains($0) } == true ? String(query.prefix(1)) : ""
        guard query != bare else { return dismiss() }
        field.stringValue = bare
        placeCaret()
        refresh()
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].selectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        QuickOpenRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PaletteCell.identifier, owner: nil) as? PaletteCell ?? PaletteCell()
        switch rows[row] {
        case .header(let name):
            cell.show(symbol: nil, trailing: .empty, label: name) { _ in
                NSAttributedString(string: name, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ThemeStore.shared.color(.ink2),
                ])
            }
        case .file(let result, let line):
            let text = result.file.text
            let path = text.string as NSString
            let name = path.substring(from: text.nameStart)
            let folderPath = text.nameStart > 0 ? path.substring(to: text.nameStart - 1) : folder.map { FileManager.default.displayName(atPath: $0.url.path) } ?? ""
            let detail = line.map { "Line \($0)" } ?? recents[result.file.url.path].map(Self.relative) ?? (result.file.boost != nil ? "Pinned" : "")
            cell.show(symbol: "doc.text", trailing: .text(detail), label: [name, folderPath, detail].filter { !$0.isEmpty }.joined(separator: ", ")) { selected in
                let title = Self.styled(name, result.positions, from: text.nameStart, size: 13, role: .title, selected: selected)
                title.append(Self.styled("   " + folderPath, text.nameStart > 0 ? result.positions.map { $0 + 3 } : [], size: 11, role: .dim, selected: selected))
                return title
            }
        case .command(let hit):
            let command = hit.command
            let value = command.value?()
            let trailing: PaletteCell.Trailing = value.map { .text($0) } ?? command.keys.map { .keys($0.caps) } ?? .empty
            let spoken = [command.group + ": " + command.title, hit.alias.map { "also \($0)" }, value, command.keys?.spoken]
            cell.show(symbol: command.symbol, trailing: trailing, label: spoken.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")) { selected in
                let title = Self.styled(command.group + ": ", [], size: 13, role: .dim, selected: selected)
                title.append(Self.styled(command.title, hit.positions, size: 13, role: .title, selected: selected))
                if let alias = hit.alias {
                    title.append(Self.styled(" (\(alias))", hit.aliasPositions.map { $0 + 2 }, size: 13, role: .dim, selected: selected))
                }
                return title
            }
        case .heading(let heading, let positions):
            let indent = String(repeating: "  ", count: max(heading.level - 1, 0))
            cell.show(symbol: "number", trailing: .text("Line \(heading.line)"),
                      label: [heading.title, heading.file, "line \(heading.line)"].filter { !$0.isEmpty }.joined(separator: ", ")) { selected in
                let title = Self.styled(indent + heading.title, positions.map { $0 + indent.utf16.count }, size: 13, role: .title, selected: selected)
                if !heading.file.isEmpty { title.append(Self.styled("   " + heading.file, [], size: 11, role: .dim, selected: selected)) }
                return title
            }
        case .line(let line):
            let lines = (target?.windowController as? MainWindowController)?.textView.map { view in
                (view.string as NSString).components(separatedBy: "\n").count
            }
            cell.show(symbol: "arrow.right.to.line", trailing: .text(lines.map { "of \($0)" } ?? ""), label: "Go to line \(line)") { selected in
                Self.styled("Go to Line \(line)", [], size: 13, role: .title, selected: selected)
            }
        case .prefix(let prefix, let title, let symbol):
            cell.show(symbol: symbol, trailing: .keys(prefix.isEmpty ? [] : [prefix]), label: title) { selected in
                Self.styled(title, [], size: 13, role: .title, selected: selected)
            }
        case .choice(let index, let positions):
            let name = choices?.names[index] ?? ""
            let current = choices?.current == index
            cell.show(symbol: current ? "checkmark" : "", trailing: .text(current ? "Current" : ""), label: name) { selected in
                Self.styled(name, positions, size: 13, role: .title, selected: selected)
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        if let choices, case .choice(let index, _) = rows[row], index != previewed {
            previewed = index
            choices.apply(index)
        }
        if let label = table.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityLabel() { announce(label) }
    }

    /// Tells VoiceOver which row Return would choose, or that nothing matches, since the keyboard stays in the field.
    private func announce(_ label: String) {
        guard isVisible, !label.isEmpty else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: label,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return Date.now.timeIntervalSince(date) < 60 ? "Just now" : formatter.localizedString(for: date, relativeTo: .now)
    }

    fileprivate enum Role { case title, dim }

    /// `text` with the letters at `positions` (offsets into the matched string, which `text` starts `from`) in
    /// semibold, in ink or the dim ink, or in the paper color on the selected row's accent.
    private static func styled(_ text: String, _ positions: [Int], from start: Int = 0, size: CGFloat, role: Role, selected: Bool)
        -> NSMutableAttributedString {
        let theme = ThemeStore.shared
        let ink = selected ? theme.color(.paper) : theme.color(.ink)
        let color = role == .title ? ink : selected ? theme.color(.paper).withAlphaComponent(0.72) : theme.color(.ink2)
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingTail
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: line,
        ])
        let strong: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: ink]
        for position in positions where position >= start && position - start < string.length {
            string.addAttributes(strong, range: NSRange(location: position - start, length: 1))
        }
        return string
    }
}

/// The results list, which never takes the keyboard from the field, and reports the pointer's moves over its rows.
private final class QuickOpenTable: NSTableView {
    var hovered: (Int, NSPoint) -> Void = { _, _ in }
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hovered(row(at: convert(event.locationInWindow, from: nil)), NSEvent.mouseLocation)
    }
}

/// A row: an SF Symbol, a one-line title with its dim group or folder, and at the right a shortcut as keycaps or a
/// value. Colors follow the row's selection.
private final class PaletteCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("palette")

    enum Trailing {
        case empty
        case text(String)
        case keys([String])
    }

    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let caps = Keycaps()
    private var leading: NSLayoutConstraint?
    private var title: (Bool) -> NSAttributedString = { _ in NSAttributedString() }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let trailing = NSStackView(views: [value, caps])
        trailing.spacing = 0
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [symbol, label, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40)
        self.leading = leading
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 20),
            leading,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PaletteCell is built in code")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { paint() }
    }

    func show(symbol name: String?, trailing: Trailing, label spoken: String, title: @escaping (Bool) -> NSAttributedString) {
        symbol.image = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        leading?.constant = name == nil ? 14 : 40
        self.title = title
        switch trailing {
        case .empty:
            value.isHidden = true
            caps.isHidden = true
        case .text(let text):
            value.stringValue = text
            value.isHidden = text.isEmpty
            caps.isHidden = true
        case .keys(let keys):
            caps.caps = keys
            caps.isHidden = keys.isEmpty
            value.isHidden = true
        }
        setAccessibilityLabel(spoken)
        paint()
    }

    private func paint() {
        let selected = backgroundStyle == .emphasized
        let theme = ThemeStore.shared
        let dim = selected ? theme.color(.paper).withAlphaComponent(0.72) : theme.color(.ink2)
        symbol.contentTintColor = dim
        value.textColor = dim
        caps.selected = selected
        label.attributedStringValue = title(selected)
    }
}

/// Each key of a shortcut in its own rounded box, at 11 points.
private final class Keycaps: NSView {
    var caps: [String] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var selected = false {
        didSet { needsDisplay = true }
    }

    private static let font = NSFont.systemFont(ofSize: 11)
    private static let height: CGFloat = 18
    private static let spacing: CGFloat = 3

    private static func width(_ cap: String) -> CGFloat {
        max(height, ceil((cap as NSString).size(withAttributes: [.font: font]).width) + 8)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: caps.map(Self.width).reduce(0, +) + Self.spacing * CGFloat(max(caps.count - 1, 0)), height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeStore.shared
        let paper = theme.color(.paper)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: selected ? paper : theme.color(.ink2)]
        var x: CGFloat = 0
        for cap in caps {
            let width = Self.width(cap)
            let box = NSRect(x: x, y: (bounds.height - Self.height) / 2, width: width, height: Self.height).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            (selected ? paper.withAlphaComponent(0.16) : theme.color(.codeBackground)).setFill()
            path.fill()
            (selected ? paper.withAlphaComponent(0.5) : theme.color(.syntax)).setStroke()
            path.lineWidth = 1
            path.stroke()
            let size = (cap as NSString).size(withAttributes: attributes)
            (cap as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attributes)
            x += width + Self.spacing
        }
    }
}

/// "Next time: ⌥⌘]" for 2 s at the foot of the window a command ran in from the palette.
@MainActor
private enum ShortcutHint {
    private static var panel: NSPanel?
    private static let caps = Keycaps()
    private static var shown = 0

    static func show(_ keys: [String], in window: NSWindow?) {
        // After the command, which may close the window or open a sheet on it.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { present(keys, in: window) }
        }
    }

    private static func present(_ keys: [String], in window: NSWindow?) {
        guard let window, window.isVisible else { return }
        let hint = panel ?? make()
        panel = hint
        caps.caps = keys
        caps.selected = false
        hint.contentView?.needsDisplay = true
        (hint.contentView?.subviews.first as? NSStackView)?.views.compactMap { $0 as? NSTextField }.forEach {
            $0.textColor = ThemeStore.shared.color(.ink2)
        }
        hint.contentView?.layoutSubtreeIfNeeded()
        let size = hint.contentView?.fittingSize ?? NSSize(width: 160, height: 30)
        hint.setFrame(NSRect(x: window.frame.midX - size.width / 2, y: window.frame.minY + 24, width: size.width, height: size.height), display: true)
        hint.parent?.removeChildWindow(hint)
        window.addChildWindow(hint, ordered: .above)
        hint.orderFront(nil)
        shown += 1
        let showing = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                guard showing == shown else { return }
                hint.parent?.removeChildWindow(hint)
                hint.orderOut(nil)
            }
        }
    }

    private static func make() -> NSPanel {
        let hint = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 30), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.hasShadow = true
        hint.ignoresMouseEvents = true
        hint.animationBehavior = .none
        hint.isReleasedWhenClosed = false
        let text = NSTextField(labelWithString: "Next time:")
        text.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [text, caps])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let ground = PanelBackground()
        ground.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: ground.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -6),
        ])
        hint.contentView = ground
        hint.setAccessibilityLabel("Shortcut")
        return hint
    }
}

/// The selected result on the theme's accent, with the row's text in the paper color.
private final class QuickOpenRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        ThemeStore.shared.color(.accent).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }
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
