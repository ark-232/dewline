import AppKit

/// The palette: one opaque Station panel over the window in front, which dims behind it. Shift-Cmd-P opens it on ">",
/// the menu bar's enabled commands and the settings; Shift-Cmd-O opens it empty, which finds Markdown files by name in
/// the window's folder, Recents and Pinned. "@" lists the open file's headings, ":" goes to a line, "#" finds headings
/// across the folder and "?" lists these prefixes; "notes@intro" and "notes:42" reach into a file. A typed prefix
/// turns into a scope chip in front of the field, and Delete on the empty field takes it back.
final class QuickOpenPanel: NSPanel, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: QuickOpenPanel?

    /// Opens the palette on commands or files; the same shortcut again closes it, the other switches.
    static func show(commands: Bool) {
        let panel = shared ?? QuickOpenPanel()
        shared = panel
        if panel.isVisible, panel.isKeyWindow {
            if panel.choices != nil || panel.query.hasPrefix(">") == commands { return panel.dismiss() }
            panel.setQuery(commands ? ">" : "")
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
        case prefix(String, title: String)
        case choice(Int, positions: [Int])
        /// A note to make in the folder when no file matches.
        case create(String)

        var selectable: Bool {
            if case .header = self { return false }
            return true
        }

        /// Headers 26 pt; every result one line at 32.
        var height: CGFloat {
            if case .header = self { return 26 }
            return 32
        }
    }

    private static let width: CGFloat = 600
    /// The input row, the horizon under it and the list's padding above and below.
    private static let chromeHeight: CGFloat = 56 + 1 + 6 + 6
    /// Nine rows show; a longer list scrolls.
    private static let listMax: CGFloat = 9 * 32 + 8
    private static let prefixes: [(String, String)] = [
        (">", "Commands and settings"),
        ("@", "Headings in this file"),
        (":", "Go to a line"),
        ("#", "Headings in the folder"),
        ("", "Files by name (add @ or : to reach into one)"),
    ]
    /// The scope chip's word for each prefix.
    private static let scopes: [Character: String] = [">": "Commands", "@": "Outline", ":": "Line", "#": "Headings", "?": "Help"]
    /// Commands offered before you type, by action, after the agent changes and the recent ones.
    private static let suggested = [
        "newWindowForTab:", "openFolder:", "findInFiles:", "toggleSource:", "toggleFocusMode:", "toggleTypewriterMode:",
        "goToLine:", "showSettings:",
    ]
    private let field = NSTextField()
    private let mark = DewMark()
    private let chip = ScopeChip()
    private let horizon = PaletteHorizon()
    private let table = QuickOpenTable()
    private let fade = TopFade()
    private let empty = NSTextField(labelWithString: "")
    private let background = PanelBackground()
    private let backdrop = Backdrop()
    private var listHeight: NSLayoutConstraint?
    /// The prefix typed first, shown as the chip and kept out of the field.
    private var scope: Character?
    /// Files with an agent's undecided changes in any open document, by path, with the writer of the latest.
    private var touched: [String: (url: URL, writer: MarkWriter)] = [:]
    /// How many of `boosted` are recents; the rest are pins.
    private var recentCount = 0

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
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.chromeHeight + 40), styleMask: [.borderless], backing: .buffered,
                   defer: true)
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
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Chrome.title
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mark.isHidden = true
        let input = NSStackView(views: [chip, field])
        input.spacing = 12
        input.alignment = .centerY
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = 32
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
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        empty.font = Chrome.label
        empty.alignment = .center
        fade.isHidden = true
        for view in [input, horizon, scroll, fade, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let listHeight = scroll.heightAnchor.constraint(equalToConstant: 40)
        self.listHeight = listHeight
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            input.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            horizon.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 56.5),
            horizon.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            horizon.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            horizon.heightAnchor.constraint(equalToConstant: 10),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 57 + 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            listHeight,
            fade.topAnchor.constraint(equalTo: scroll.topAnchor),
            fade.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            fade.heightAnchor.constraint(equalToConstant: 24),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        return root
    }

    /// The top fade shows once the list scrolls under it.
    @objc private func scrolled(_ notification: Notification) {
        fade.isHidden = ((notification.object as? NSClipView)?.bounds.minY ?? 0) <= 0
    }

    /// What the palette searches: the scope's prefix, then the field.
    private var query: String {
        (scope.map(String.init) ?? "") + field.stringValue
    }

    /// Sets the query; a leading prefix goes to the chip.
    private func setQuery(_ text: String) {
        if let first = text.first, Self.scopes[first] != nil {
            scope = first
            field.stringValue = String(text.dropFirst())
        } else {
            scope = nil
            field.stringValue = text
        }
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
        recentCount = visits.count
        touched = Self.touched()
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

        setQuery(showsCommands ? ">" : "")
        pendingChoice = nil
        merging?.cancel()
        files = QuickOpen.merge([], boosted: boosted, in: folder)
        if let indexed = index?.files { merge(indexed) }
        recolor()
        refresh()
        dim(target)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        placeCaret()
    }

    /// Dims the window the palette belongs to, under the panel; a click there passes through and closes the panel.
    private func dim(_ window: NSWindow?) {
        guard let content = window?.contentView else { return backdrop.removeFromSuperview() }
        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        content.addSubview(backdrop, positioned: .above, relativeTo: nil)
    }

    /// Open files carrying an agent's undecided changes, each with the writer of its latest one.
    private static func touched() -> [String: (url: URL, writer: MarkWriter)] {
        var touched: [String: (url: URL, writer: MarkWriter)] = [:]
        for case let document as MarkdownDocument in NSDocumentController.shared.documents {
            guard let live = document.live,
                let latest = live.changes.filter({ $0.value.marked && $0.value.origin != .user }).max(by: { $0.key < $1.key })
            else { continue }
            touched[live.url.path] = (live.url, MarkWriter(latest.value.origin))
        }
        return touched
    }

    private func placeCaret() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let theme = ThemeStore.shared
        editor.insertionPointColor = theme.color(.signal)
        editor.selectedTextAttributes = [.backgroundColor: theme.color(.selection)]
        editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    /// The theme's colors on the panel's own views; rows take them as they draw.
    private func recolor() {
        let theme = ThemeStore.shared
        for view in [background, horizon, chip, fade, backdrop, mark] as [NSView] {
            view.needsDisplay = true
        }
        field.textColor = theme.color(.ink)
        empty.textColor = theme.color(.ink3)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = theme.color(.signal)
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
            .font: Chrome.title, .foregroundColor: ThemeStore.shared.color(.ink3),
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
        if choices == nil, case .files = Self.mode(of: query) { refresh() }
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
        let query = query
        if let choices {
            chrome(choices.title, chip: choices.title, placeholder: "Type to filter")
            let letters = FuzzyText.query(query)
            show(choices.names.enumerated().compactMap { index, name -> Row? in
                if letters.isEmpty { return .choice(index, positions: []) }
                return FuzzyText(name).forgivingMatch(letters).map { .choice(index, positions: $0.positions) }
            })
            return
        }
        switch Self.mode(of: query) {
        case .commands(let text):
            chrome("Command Palette", placeholder: "Type a command")
            show(commandRows(text))
        case .help:
            chrome("Palette Prefixes", placeholder: "Pick a prefix")
            show(Self.prefixes.map { .prefix($0.0, title: $0.1) })
        case .headings(let text):
            chrome("Go to Heading", placeholder: "Go to a heading in this file")
            let headings = currentHeadings()
            show(PaletteHeading.rank(text, in: headings)?.map { .heading($0.heading, positions: $0.positions) } ?? [])
        case .line(let text):
            chrome("Go to Line", placeholder: "Type a line number")
            let number = Int(text.trimmingCharacters(in: .whitespaces))
            show(number.map { [.line($0)] } ?? [])
        case .folderHeadings(let text):
            chrome("Headings in Folder", placeholder: "Find a heading in the folder")
            guard let urls = index?.files?.map(\.url) else { return show([]) }
            let folder = folder
            let scan = headingScan ?? Task { await PaletteHeading.scan(urls, in: folder) }
            headingScan = scan
            run { _ in
                guard let ranked = await Self.ranked(text, in: await scan.value) else { return nil }
                return ranked.map { .heading($0.heading, positions: $0.positions) }
            }
        case .files(let text):
            chrome("Quick Open", placeholder: "Find a note. Type > for commands.")
            if text.allSatisfy(\.isWhitespace) {
                show(restingFileRows())
            } else {
                run { panel in
                    guard let found = await Self.ranked(text, in: panel.files) else { return nil }
                    return panel.mixedRows(found, commands: PaletteRank.rank(text, in: panel.commands, frecency: panel.frecency))
                }
            }
        case .fileLine(let text, let line):
            chrome("Go to Line in File", placeholder: "Find a note. Type > for commands.")
            run { panel in await Self.ranked(text, in: panel.files)?.map { .file($0, line: line) } }
        case .fileHeadings(let text, let heading):
            chrome("Go to Heading in File", placeholder: "Find a note. Type > for commands.")
            run { panel in
                guard let top = await Self.ranked(text, in: panel.files)?.first else { return nil }
                let headings = await panel.headings(of: top.file)
                return await Self.ranked(heading, in: headings)?.map { .heading($0.heading, positions: $0.positions) }
            }
        }
    }

    /// Names the panel for VoiceOver and shows the chip for a scope or a setting's values, else the mark.
    private func chrome(_ name: String, chip word: String? = nil, placeholder text: String) {
        title = name
        field.setAccessibilityLabel(name)
        let word = word ?? scope.flatMap { Self.scopes[$0] }
        chip.title = word ?? ""
        chip.isHidden = word == nil
        placeholder(text)
        updateHorizon()
    }

    /// The lit stretch of the horizon runs from the panel's left edge to the end of the typed text.
    private func updateHorizon() {
        background.layoutSubtreeIfNeeded()
        let typed = ceil((field.stringValue as NSString).size(withAttributes: [.font: Chrome.title]).width)
        let start = field.convert(NSPoint.zero, to: background).x + 2
        horizon.lit = min(start + typed, background.bounds.width - 24)
    }

    /// With nothing typed: files with an agent's changes (three at most), then recents, then pins.
    private func restingFileRows() -> [Row] {
        var rows: [Row] = []
        let rest = QuickOpen.rank("", in: files) ?? []
        let recent = rest.filter { ($0.file.boost ?? 0) < recentCount }
        let pinned = rest.filter { ($0.file.boost ?? 0) >= recentCount }
        if !recent.isEmpty { rows += [.header("Recent")] + recent.map { .file($0, line: nil) } }
        if !pinned.isEmpty { rows += [.header("Pinned")] + pinned.map { .file($0, line: nil) } }
        return rows
    }

    /// An unprefixed search's groups: the files, then the three best commands whose titles hold the letters. A lone
    /// group shows without its header.
    private func mixedRows(_ found: [QuickOpenResult], commands hits: [PaletteHit]) -> [Row] {
        let commands = hits.filter { !$0.positions.isEmpty }.prefix(3)
        let groups: [(String, [Row])] = [
            ("Notes", found.map { .file($0, line: nil) }),
            ("Commands", commands.map(Row.command)),
        ].filter { !$0.1.isEmpty }
        guard groups.count > 1 else { return groups.first?.1 ?? [] }
        return groups.flatMap { [Row.header($0.0)] + $0.1 }
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

    /// The commands matching `query`; before you type, the recent ones, then the suggested.
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
        group("Recent", PaletteHistory.recent.compactMap { id in commands.first { $0.id == id } })
        let suggested = Self.suggested.compactMap { action in commands.first { $0.selector.map(NSStringFromSelector) == action } }
        group("Commands", suggested + commands.filter { $0.id == "settings:theme" })
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
        var rows = rows
        if rows.isEmpty, folder != nil, index?.files != nil, case .files(let text) = Self.mode(of: query), !text.allSatisfy(\.isWhitespace) {
            rows = [.create(text.trimmingCharacters(in: .whitespaces))]
        }
        self.rows = rows
        table.deselectAll(nil)
        table.reloadData()
        empty.stringValue = emptyText()
        empty.isHidden = !rows.isEmpty
        if rows.isEmpty {
            announce(empty.stringValue)
        } else if let first = rows.firstIndex(where: { isCurrentChoice($0) }) ?? rows.firstIndex(where: { $0.selectable && !Self.isDestructive($0) })
            ?? rows.firstIndex(where: \.selectable)
        {
            select(first)
        }
        place()
        if let newTab = pendingChoice {
            pendingChoice = nil
            choose(table.selectedRow, newTab: newTab)
        }
    }

    /// Keep All and Revert All never take the selection on their own.
    private static func isDestructive(_ row: Row) -> Bool {
        guard case .command(let hit) = row, let action = hit.command.selector.map(NSStringFromSelector) else { return false }
        return ["keepAllChanges:", "revertAllChanges:"].contains(action)
    }

    private func isCurrentChoice(_ row: Row) -> Bool {
        guard let choices, case .choice(let index, _) = row else { return false }
        return index == choices.current
    }

    private func emptyText() -> String {
        if let choices { return "No \(choices.title.lowercased()) matches." }
        switch Self.mode(of: query) {
        case .commands(let text): return "No commands match \(Self.quoted(text))."
        case .help: return ""
        case .headings: return target?.windowController is MainWindowController ? "No headings match." : "Open a file to list its headings."
        case .line: return "Type a line number."
        case .folderHeadings: return folder == nil ? "Open a folder to find headings across it." : "No headings match."
        case .fileHeadings: return "No heading matches in that file."
        case .files(let text) where text.allSatisfy(\.isWhitespace):
            if let folder { return "Type a name to find a note in \(FileManager.default.displayName(atPath: folder.url.path))." }
            return "Type a name to find a note you opened or pinned."
        case .files(let text), .fileLine(let text, _):
            return index != nil && index?.files == nil ? "Listing notes…" : "No notes match \(Self.quoted(text))."
        }
    }

    /// "plan" as "plan.md"; a name with its own Markdown extension keeps it.
    static func noteName(_ text: String) -> String {
        let name = text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) ? name : name + ".md"
    }

    private static func quoted(_ text: String) -> String {
        "\u{201C}\(text.trimmingCharacters(in: .whitespaces))\u{201D}"
    }

    /// Sizes the panel to its rows, about seven and a half at most, and puts its top 22% down the target window,
    /// centered across it.
    private func place() {
        let list = rows.isEmpty ? 40 : min(rows.map(\.height).reduce(0, +), Self.listMax)
        listHeight?.constant = list
        let height = Self.chromeHeight + list
        let screen = target?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let anchor = target?.frame ?? visible
        var frame = NSRect(x: anchor.midX - Self.width / 2, y: anchor.maxY - anchor.height * 0.22 - height, width: Self.width, height: height)
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
        backdrop.removeFromSuperview()
        orderOut(nil)
        files = []
        touched = [:]
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
        case .prefix(let prefix, _):
            setQuery(prefix)
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
        case .create(let name):
            guard let folder else { return NSSound.beep() }
            dismiss()
            FileCommand.send(FileCommand.newNamedNote, NewNoteRequest(folder: folder.url, name: Self.noteName(name)), from: nil)
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
        controller.showWindow(nil)
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
        choicesFrom = (query, id)
        choices = level
        previewed = level.current
        setQuery("")
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
        setQuery(from.query)
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

    /// A prefix typed first, or pasted with its query, moves into the chip.
    func controlTextDidChange(_ notification: Notification) {
        if scope == nil, choices == nil, let first = field.stringValue.first, Self.scopes[first] != nil {
            setQuery(field.stringValue)
            placeCaret()
        }
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(deleteBackward(_:)) where field.stringValue.isEmpty && choices != nil:
            leaveChoices()
        case #selector(deleteBackward(_:)) where field.stringValue.isEmpty && scope != nil:
            scope = nil
            refresh()
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

    /// Escape: back from a setting's values, else closes.
    private func cancel() {
        if choices != nil { return leaveChoices() }
        dismiss()
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].selectable
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) ? rows[row].height : 40
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .header(let name) = rows[row] {
            let header = tableView.makeView(withIdentifier: PaletteHeader.identifier, owner: nil) as? PaletteHeader ?? PaletteHeader()
            header.title = name
            return header
        }
        let cell = tableView.makeView(withIdentifier: PaletteCell.identifier, owner: nil) as? PaletteCell ?? PaletteCell()
        cell.content = content(of: rows[row])
        return cell
    }

    /// What a row draws, the hints its selection shows and what VoiceOver says for it.
    private func content(of row: Row) -> PaletteCell.Content {
        var content = PaletteCell.Content()
        func spoken(_ parts: [String?]) -> String {
            parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        switch row {
        case .header:
            break
        case .file(let result, let line):
            let text = result.file.text
            let path = text.string as NSString
            let name = path.substring(from: text.nameStart)
            let folderPath = text.nameStart > 0 ? path.substring(to: text.nameStart - 1) : folder.map { FileManager.default.displayName(atPath: $0.url.path) } ?? ""
            let writer = touched[result.file.url.path]?.writer
            let detail = line.map { "line \($0)" } ?? recents[result.file.url.path].map { relativeTime($0) } ?? (result.file.boost != nil ? "pinned" : "")
            let positions = result.positions.compactMap { $0 >= text.nameStart ? $0 - text.nameStart : nil }
            content.lead = writer.map { _ in .dot(Chrome.color(.accent)) } ?? .none
            content.title = [.init(name, positions: positions, dimUnmatched: !positions.isEmpty)]
            let folderName = (folderPath as NSString).lastPathComponent
            content.subtitle = folderName
            content.trailing = .text(detail)
            content.hints = [("↩", "open"), ("⌘↩", "new tab")]
            content.spoken = spoken([name, folderPath, writer.map { "changed by \($0.name)" }, detail])
        case .command(let hit):
            let command = hit.command
            let value = command.value?()
            content.title = [.init(command.title, positions: hit.positions)]
            if let alias = hit.alias { content.title.append(.init("(\(alias))", positions: hit.aliasPositions.map { $0 + 1 }, style: .aside)) }
            content.trailing = value.map { .text($0) } ?? command.keys.map { .text($0.caps.joined()) } ?? .empty
            content.hints = switch command.action {
            case .menu: [("↩", "run")]
            case .toggle: [("↩", "switch")]
            case .choose: [("↩", "values")]
            }
            content.spoken = spoken([command.group + ": " + command.title, hit.alias.map { "also \($0)" }, value, command.keys?.spoken])
        case .heading(let heading, let positions):
            content.lead = .tag("h\(heading.level)")
            content.title = [.init(heading.title, positions: positions)]
            if heading.file.isEmpty {
                content.trailing = .text("line \(heading.line)")
            } else {
                content.subtitle = "\(heading.file) · line \(heading.line)"
            }
            content.hints = heading.url == nil ? [("↩", "go")] : [("↩", "go"), ("⌘↩", "new tab")]
            content.spoken = spoken([heading.title, heading.file, "line \(heading.line)"])
        case .line(let line):
            let lines = (target?.windowController as? MainWindowController)?.textView.map { view in
                (view.string as NSString).components(separatedBy: "\n").count
            }
            content.lead = .tag(":")
            content.title = [.init("Go to line \(line)")]
            content.trailing = .text(lines.map { "of \($0)" } ?? "")
            content.hints = [("↩", "go")]
            content.spoken = "Go to line \(line)"
        case .create(let name):
            let where_ = folder.map { FileManager.default.displayName(atPath: $0.url.path) } ?? ""
            content.title = [.init("Create \u{201C}\(Self.noteName(name))\u{201D} in \(where_)")]
            content.hints = [("↩", "create")]
            content.spoken = "Create \(Self.noteName(name)) in \(where_)"
        case .prefix(let prefix, let title):
            content.title = [.init(title)]
            content.trailing = .text(prefix)
            content.hints = [("↩", "use")]
            content.spoken = title
        case .choice(let index, let positions):
            let name = choices?.names[index] ?? ""
            let current = choices?.current == index
            content.lead = current ? .bead : .none
            content.title = [.init(name, positions: positions)]
            content.trailing = .text(current ? "current" : "")
            content.hints = [("↩", "keep"), ("⎋", "restore")]
            content.spoken = spoken([name, current ? "current" : nil])
        }
        return content
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

/// A result row on one line, drawn: a 16 pt leading slot (a writer's dot, a mono tag or the current value's bead), the
/// title in Bricolage with its matched letters underlined in signal, an optional mono subtitle after it, and at the
/// right a value or keycaps. On the selected row the keyboard hints in mono take the value's place.
private final class PaletteCell: NSView, ChromeSelectable {
    static let identifier = NSUserInterfaceItemIdentifier("palette")

    enum Lead {
        case none
        case dot(NSColor)
        case tag(String)
        case bead
    }

    enum Trailing {
        case empty
        case text(String)
        case keys([String])
    }

    /// A run of the title line: the title, or an aside after it in `ink3`, such as an alias or a command's menu.
    struct Segment {
        enum Style { case title, aside }
        let text: String
        var positions: [Int]
        var style: Style
        /// Unmatched letters drop to `ink2`, so a file name's match stands out.
        var dimUnmatched: Bool

        init(_ text: String, positions: [Int] = [], style: Style = .title, dimUnmatched: Bool = false) {
            self.text = text
            self.positions = positions
            self.style = style
            self.dimUnmatched = dimUnmatched
        }
    }

    struct Content {
        var lead = Lead.none
        var title: [Segment] = []
        var subtitle = ""
        var trailing = Trailing.empty
        var hints: [(key: String, word: String)] = []
        var spoken = ""
    }

    var content = Content() {
        didSet {
            setAccessibilityLabel(content.spoken)
            needsDisplay = true
        }
    }

    var selected = false {
        didSet {
            if selected != oldValue { needsDisplay = true }
        }
    }

    /// Where the title font's baseline sits below the top of its line.
    private static let baseline = NSLayoutManager().defaultBaselineOffset(for: Chrome.brand(14))

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("PaletteCell is built in code")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let titleY = bounds.midY
        var right = bounds.maxX - 12
        let hinting = selected && !content.hints.isEmpty
        switch content.trailing {
        case .empty:
            break
        case .text(let text) where !text.isEmpty && !hinting:
            let string = NSAttributedString(string: text, attributes: [.font: Chrome.label, .foregroundColor: Chrome.color(.ink2)])
            let size = string.size()
            string.draw(at: NSPoint(x: right - size.width, y: titleY - size.height / 2))
            right -= ceil(size.width) + 12
        case .keys(let keys) where !keys.isEmpty:
            let width = Keycap.width(keys)
            Keycap.draw(keys, x: right - width, midY: titleY, onFill: false, alpha: selected ? 1 : 0.6)
            right -= width + 12
        default:
            break
        }
        if hinting {
            let hints = Self.hints(content.hints)
            let size = hints.size()
            hints.draw(at: NSPoint(x: right - size.width, y: titleY - size.height / 2))
            right -= ceil(size.width) + 16
        }
        drawLead(midY: titleY)
        let left: CGFloat = 44
        let width = max(right - left, 0)
        guard !content.subtitle.isEmpty else {
            drawTitle(x: left, width: width, midY: titleY)
            return
        }
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSAttributedString(string: content.subtitle, attributes: [
            .font: Chrome.label, .foregroundColor: Chrome.color(.ink2), .paragraphStyle: line,
        ])
        // The title keeps at least 60% of the room; the subtitle takes what is left and gives up its middle first.
        let wanted = ceil(subtitle.size().width)
        let title = drawTitle(x: left, width: max(width * 0.6, width - wanted - 12), midY: titleY)
        let x = left + title + 12
        let height = ceil(subtitle.size().height)
        subtitle.draw(with: NSRect(x: x, y: titleY - height / 2 + 1, width: max(left + width - x, 0), height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawLead(midY: CGFloat) {
        let dot = NSRect(x: 21, y: midY - 3, width: 6, height: 6)
        switch content.lead {
        case .none:
            break
        case .dot(let color):
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        case .bead:
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = Chrome.color(.glow).withAlphaComponent(CGFloat(Chrome.glowOpacity(dark: effectiveAppearance.isDark)))
            glow.shadowBlurRadius = 4
            glow.shadowOffset = .zero
            glow.set()
            Chrome.color(.signal).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .tag(let tag):
            let string = NSAttributedString(string: tag, attributes: [.font: Chrome.mono(10.5), .foregroundColor: Chrome.color(.ink3)])
            let size = string.size()
            string.draw(at: NSPoint(x: 24 - size.width / 2, y: midY - size.height / 2))
        }
    }

    /// The title line, truncated at the tail, with a 1.5 pt signal underline 2 pt under the baseline of each run of
    /// matched letters that is not cut off. Returns the width it took.
    @discardableResult
    private func drawTitle(x: CGFloat, width: CGFloat, midY: CGFloat) -> CGFloat {
        let (string, matched) = Self.title(content.title)
        let size = string.size()
        let box = NSRect(x: x, y: midY - ceil(size.height) / 2, width: width, height: ceil(size.height))
        string.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let taken = min(ceil(size.width), width)
        guard !matched.isEmpty else { return taken }
        // Past this x the tail is cut off and an ellipsis drawn.
        let limit = size.width <= width ? box.maxX : box.maxX - 14
        let y = box.minY + Self.baseline + 2
        Chrome.color(.signal).setFill()
        var runs: [(start: Int, end: Int)] = []
        for position in matched.sorted() {
            if let last = runs.last, last.end == position {
                runs[runs.count - 1].end = position + 1
            } else {
                runs.append((position, position + 1))
            }
        }
        for run in runs {
            let x0 = box.minX + string.attributedSubstring(from: NSRange(location: 0, length: run.start)).size().width
            let x1 = box.minX + string.attributedSubstring(from: NSRange(location: 0, length: run.end)).size().width
            guard x1 <= limit else { break }
            NSRect(x: x0, y: y, width: x1 - x0, height: 1.5).fill()
        }
        return taken
    }

    /// The segments as one line two spaces apart, and the offsets of their matched letters in it.
    private static func title(_ segments: [Segment]) -> (NSAttributedString, [Int]) {
        let result = NSMutableAttributedString()
        var matched: [Int] = []
        for segment in segments where !segment.text.isEmpty {
            let aside = segment.style == .aside
            let size: CGFloat = aside ? 13 : 14
            if result.length > 0 { result.append(NSAttributedString(string: "  ", attributes: [.font: Chrome.brand(size)])) }
            let start = result.length
            let color = Chrome.color(aside ? .ink3 : segment.dimUnmatched ? .ink2 : .ink)
            result.append(NSAttributedString(string: segment.text, attributes: [.font: Chrome.brand(size), .foregroundColor: color]))
            let length = (segment.text as NSString).length
            let strong: [NSAttributedString.Key: Any] = [.font: Chrome.brand(size, weight: 560), .foregroundColor: Chrome.color(aside ? .ink2 : .ink)]
            for position in segment.positions where position >= 0 && position < length {
                result.addAttributes(strong, range: NSRange(location: start + position, length: 1))
                matched.append(start + position)
            }
        }
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: line, range: NSRange(location: 0, length: result.length))
        return (result, matched)
    }

    /// "↩ open   ⌘↩ new tab": keys in `ink2`, words in `ink3`, mono 11.
    private static func hints(_ hints: [(key: String, word: String)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = Chrome.status
        for (index, hint) in hints.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            result.append(NSAttributedString(string: hint.key, attributes: [.font: font, .foregroundColor: Chrome.color(.ink2)]))
            result.append(NSAttributedString(string: " " + hint.word, attributes: [.font: font, .foregroundColor: Chrome.color(.ink2)]))
        }
        return result
    }
}

/// A group header: Bricolage 11.5 / 600 in sentence case, `ink3`, sitting on the bottom of its 30 pt row.
private final class PaletteHeader: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("paletteHeader")

    var title = "" {
        didSet {
            setAccessibilityLabel(title)
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("PaletteHeader is built in code")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let string = Chrome.sectionTitle(title, color: Chrome.color(.ink3))
        string.draw(at: NSPoint(x: 12, y: bounds.maxY - 6 - string.size().height))
    }
}

/// The selected row: an ink wash at 8 pt radius. No hover.
private final class PaletteRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            // A row view being set up has no columns yet; `didAddSubview` passes the state on once its cell arrives.
            guard isSelected != oldValue, numberOfColumns > 0 else { return }
            (view(atColumn: 0) as? ChromeSelectable)?.selected = isSelected
        }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        Chrome.wash.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ChromeSelectable)?.selected = isSelected
    }
}

/// A shortcut as Station keycaps, one cap per key.
private final class Keycaps: NSView {
    var caps: [String] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Keycap.width(caps), height: Keycap.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Keycap.draw(caps, x: 0, midY: bounds.midY, onFill: false)
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
        hint.contentView?.needsDisplay = true
        (hint.contentView?.subviews.first as? NSStackView)?.views.compactMap { $0 as? NSTextField }.forEach {
            $0.textColor = Chrome.color(.ink2)
        }
        hint.contentView?.layoutSubtreeIfNeeded()
        let size = hint.contentView?.fittingSize ?? NSSize(width: 160, height: 32)
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
        let hint = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 32), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.hasShadow = true
        hint.ignoresMouseEvents = true
        hint.animationBehavior = .none
        hint.isReleasedWhenClosed = false
        let text = NSTextField(labelWithString: "Next time:")
        text.font = Chrome.label
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

/// The panel's ground: opaque `raised` at a 14 pt radius with a `strokeSubtle` edge, and in dark a 1 pt highlight of
/// `ink` at 6% along the inside of the top edge. No vibrancy.
private final class PanelBackground: NSView {
    private let highlight = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.wantsLayer = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            highlight.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PanelBackground is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.color(.raised).cgColor
        layer?.borderColor = Chrome.strokeSubtle.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        highlight.layer?.backgroundColor = effectiveAppearance.isDark ? Chrome.color(.ink).withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor
    }
}

/// The horizon under the input, the editor's line in small: a `hairline` across the panel, lit in signal with its glow
/// from the left edge to `lit`, where a bead sits, then fading out over 24 pt.
private final class PaletteHorizon: NSView {
    var lit: CGFloat = 0 {
        didSet {
            if lit != oldValue { needsDisplay = true }
        }
    }

    private let rule = CALayer()
    private let glowing = CAGradientLayer()
    private let bead = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Only the rule draws; the lit stretch and its bead are gone.
        layer?.addSublayer(rule)
        glowing.startPoint = CGPoint(x: 0, y: 0.5)
        glowing.endPoint = CGPoint(x: 1, y: 0.5)
        glowing.shadowOffset = .zero
        glowing.shadowRadius = 3
        bead.cornerRadius = 4.5
        bead.borderWidth = 1.5
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("PaletteHorizon is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let appearance = effectiveAppearance
        let signal = Chrome.color(.signal).resolved(for: appearance)
        let mid = bounds.midY
        let lit = min(max(lit, 0), bounds.width)
        let end = min(lit + 24, bounds.width)
        rule.frame = NSRect(x: 0, y: mid - 0.5, width: bounds.width, height: 1)
        rule.backgroundColor = Chrome.color(.hairline).resolved(for: appearance).cgColor
        glowing.frame = NSRect(x: 0, y: mid - 1, width: end, height: 2)
        glowing.colors = [signal.cgColor, signal.cgColor, signal.withAlphaComponent(0).cgColor]
        glowing.locations = [0, NSNumber(value: Double(end > 0 ? lit / end : 0)), 1]
        glowing.shadowColor = Chrome.color(.glow).resolved(for: appearance).cgColor
        glowing.shadowOpacity = Chrome.glowOpacity(dark: appearance.isDark)
        // A 6 pt bead in a 1.5 pt ring of the panel's color, so it reads as sitting on the line.
        bead.frame = NSRect(x: lit - 4.5, y: mid - 4.5, width: 9, height: 9)
        bead.backgroundColor = signal.cgColor
        bead.borderColor = Chrome.color(.raised).resolved(for: appearance).cgColor
    }
}

/// The scope a typed prefix sets, in front of the field: mono 11 `signal` on the wash, 22 pt tall, 6 pt radius.
private final class ScopeChip: NSView {
    var title = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var string: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Chrome.section, .foregroundColor: Chrome.color(.ink2)])
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("ScopeChip is built in code")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(string.size().width) + 16, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.wash.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let string = string
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// A 24 pt fade from the panel's color at the top of the list, shown while rows scroll under it.
private final class TopFade: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let raised = Chrome.color(.raised)
        NSGradient(starting: raised, ending: raised.withAlphaComponent(0))?.draw(in: bounds, angle: -90)
    }
}

/// The dim over the window behind the palette: `rgba(4,9,15,0.6)` in dark, `rgba(17,27,40,0.5)` in light. Clicks pass
/// through it.
private final class Backdrop: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("Backdrop is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        let dim = effectiveAppearance.isDark
            ? NSColor(srgbRed: 4 / 255, green: 9 / 255, blue: 15 / 255, alpha: 0.6)
            : NSColor(srgbRed: 17 / 255, green: 27 / 255, blue: 40 / 255, alpha: 0.5)
        layer?.backgroundColor = dim.cgColor
    }
}
