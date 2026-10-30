import AppKit
import MdCore

/// Find in Files' search: the matches of a query in a list of files, searched off the main thread a batch of files at a
/// time so they arrive as they're found. Each search waits, 150 ms by default, and cancels the one before it, so typing
/// searches once it pauses. A search stops at `limit` matches.
@MainActor
final class FileSearch {
    private let limit: Int
    private let batch: Int
    private(set) var results: [FileMatches] = []
    private(set) var matchCount = 0
    /// The search stopped at `limit` with matches left.
    private(set) var stopped = false
    private(set) var isSearching = false
    /// Called with true when a search's first batch, or an empty query, replaces the results, and with false when a
    /// later batch adds to them or the search ends.
    var changed: (_ replaced: Bool) -> Void = { _ in }
    private var task: Task<Void, Never>?

    init(limit: Int = 10_000, batch: Int = 64) {
        self.limit = limit
        self.batch = batch
    }

    /// Searches `files` in order for `query` after `delay`. The results stay until the first batch replaces them; an
    /// empty query clears them at once.
    func search(_ query: String, options: SearchOptions, in files: [URL], after delay: Duration = .milliseconds(150)) {
        task?.cancel()
        task = nil
        isSearching = !query.isEmpty
        guard isSearching else {
            (results, matchCount, stopped) = ([], 0, false)
            changed(true)
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run(query, options: options, files: files)
        }
    }

    /// Stops the search in flight and keeps the results it has found.
    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    private func run(_ query: String, options: SearchOptions, files: [URL]) async {
        var first = true
        var count = 0
        for start in stride(from: 0, to: files.count, by: batch) {
            let urls = Array(files[start..<min(start + batch, files.count)])
            let remaining = limit - count
            let found = await Task.detached(priority: .utility) {
                textMatches(of: query, in: urls, options: options, limit: remaining)
            }.value
            guard !Task.isCancelled else { return }
            let added = found.files
            count += added.reduce(0) { $0 + $1.matches.count }
            if first {
                results = added
            } else {
                results += added
            }
            (matchCount, stopped) = (count, found.stopped)
            if first || !added.isEmpty {
                changed(first)
                guard !Task.isCancelled else { return }
            }
            first = false
            if stopped { break }
        }
        if first {
            (results, matchCount, stopped) = ([], 0, false)
        }
        isSearching = false
        changed(first)
    }
}

/// Find in Files in the sidebar (synthesis 2.7): a search field with Match Case and Whole Word, a line counting the
/// matches, then the matches grouped by file, each on its line with the match marked.
final class FindInFilesController: NSViewController, NSSearchFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Opens a file from the results, at a match when there is one, in a new tab when asked.
    var reveal: (URL, TextMatch?, _ newTab: Bool) -> Void = { _, _, _ in }
    /// Leaves the search for the file tree.
    var close: () -> Void = {}

    private let folder: Folder
    private let index: FolderIndex
    private let search = FileSearch()
    private let field = NSSearchField()
    private let options = NSSegmentedControl()
    private let status = NSTextField(labelWithString: "")
    private let outlineView = ResultsOutlineView()
    private var files: [ResultFile] = []
    /// Set while a query waits for the folder's first listing.
    private var waitsForFiles = false
    /// Set from a query's search until its first batch replaces the results.
    private var pending = false
    private var wasSearching = false

    init(folder: Folder) {
        self.folder = folder
        index = FolderIndex.of(folder)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FindInFilesController is built in code")
    }

    override func loadView() {
        field.placeholderString = "Find in Files"
        field.setAccessibilityLabel("Find in Files")
        field.delegate = self
        if let cancel = (field.cell as? NSSearchFieldCell)?.cancelButtonCell {
            cancel.target = self
            cancel.action = #selector(clear)
        }
        options.trackingMode = .selectAny
        options.segmentCount = 2
        for (segment, (symbol, name)) in [("textformat", "Match Case"), ("character.textbox", "Whole Word")].enumerated() {
            options.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: name), forSegment: segment)
            options.setToolTip(name, forSegment: segment)
            options.setWidth(28, forSegment: segment)
        }
        options.target = self
        options.action = #selector(optionsChanged)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: .init("match"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.allowsTypeSelect = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked)
        outlineView.setAccessibilityLabel("Matches")
        outlineView.opens = { [weak self] row, newTab in self?.open(row, newTab: newTab) }
        outlineView.closes = { [weak self] in self?.leave() }
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        for view in [field, options, status, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            options.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            options.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            options.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            status.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        search.changed = { [weak self] replaced in self?.resultsChanged(replaced: replaced) }
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged(_:)), name: FolderIndex.changed, object: index)
        showStatus()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    /// Focuses the field with its text selected and searches again, since the files may have changed.
    func begin() {
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        run(after: .zero)
    }

    private func run(after delay: Duration = .milliseconds(150)) {
        let query = field.stringValue
        let chosen = SearchOptions(matchCase: options.isSelected(forSegment: 0), wholeWord: options.isSelected(forSegment: 1))
        waitsForFiles = !query.isEmpty && index.files == nil
        pending = true
        search.search(waitsForFiles ? "" : query, options: chosen, in: index.files?.map(\.url) ?? [], after: delay)
        showStatus()
    }

    /// Returns to the file tree, stopping the search; the next `begin` runs it again.
    private func leave() {
        search.cancel()
        close()
    }

    @objc private func indexChanged(_ notification: Notification) {
        if waitsForFiles { run(after: .zero) }
    }

    @objc private func optionsChanged() {
        run(after: .zero)
    }

    /// The field's clear button ends the search.
    @objc private func clear() {
        field.stringValue = ""
        leave()
    }

    func controlTextDidChange(_ notification: Notification) {
        run()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            run(after: .zero)
        case #selector(cancelOperation(_:)):
            leave()
        case #selector(moveDown(_:)):
            guard !files.isEmpty else { return false }
            view.window?.makeFirstResponder(outlineView)
            if outlineView.selectedRow < 0 { outlineView.selectRowIndexes([1], byExtendingSelection: false) }
        default:
            return false
        }
        return true
    }

    // MARK: Results

    private func resultsChanged(replaced: Bool) {
        if replaced {
            pending = false
            files = search.results.map(ResultFile.init)
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
        } else if search.results.count > files.count {
            let added = search.results[files.count...].map(ResultFile.init)
            let rows = IndexSet(integersIn: files.count..<files.count + added.count)
            files += added
            outlineView.insertItems(at: rows, inParent: nil, withAnimation: [])
            for file in added {
                outlineView.expandItem(file)
            }
        }
        showStatus()
        // The keyboard stays in the field, so VoiceOver hears what a search found when it ends.
        if wasSearching, !search.isSearching {
            NSAccessibility.post(element: field, notification: .announcementRequested, userInfo: [
                .announcement: status.stringValue,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
        wasSearching = search.isSearching
    }

    private func showStatus() {
        let (matches, count) = (search.matchCount, search.results.count)
        let found = "\(matches.formatted()) \(matches == 1 ? "match" : "matches") in \(count.formatted()) \(count == 1 ? "file" : "files")"
        status.stringValue = if field.stringValue.isEmpty {
            "Type to search the Markdown files in \(FileManager.default.displayName(atPath: folder.url.path))."
        } else if waitsForFiles {
            "Listing files…"
        } else if pending {
            "Searching…"
        } else if search.stopped {
            "Stopped at \(found)"
        } else if search.isSearching {
            matches == 0 ? "Searching…" : "\(found) so far"
        } else {
            matches == 0 ? "No matches" : found
        }
    }

    /// A click opens in this tab and a Command-click in a new one.
    @objc private func clicked() {
        open(outlineView.clickedRow, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func open(_ row: Int, newTab: Bool) {
        switch outlineView.item(atRow: row) {
        case let line as ResultLine: reveal(line.url, line.match, newTab)
        case let file as ResultFile: reveal(file.url, nil, newTab)
        default: break
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ResultFile)?.lines.count ?? (item == nil ? files.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ResultFile)?.lines[index] ?? files[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ResultFile
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is ResultFile ? 26 : 22
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let file = item as? ResultFile {
            let cell = outlineView.makeView(withIdentifier: FileResultCell.identifier, owner: nil) as? FileResultCell ?? FileResultCell()
            let path = folder.relativePath(of: file.url.deletingLastPathComponent()) ?? ""
            cell.show(file.url.lastPathComponent, in: path, count: file.lines.count)
            return cell
        }
        let line = item as! ResultLine
        let cell = outlineView.makeView(withIdentifier: LineResultCell.identifier, owner: nil) as? LineResultCell ?? LineResultCell()
        cell.show(line.match)
        cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Go to Match") { [weak self] in
            self?.reveal(line.url, line.match, false)
            return true
        }])
        return cell
    }
}

/// A file in the results, with its matches as the rows under it.
private final class ResultFile {
    let url: URL
    let lines: [ResultLine]

    init(_ found: FileMatches) {
        url = found.url
        lines = found.matches.map { ResultLine(url: found.url, match: $0) }
    }
}

private final class ResultLine {
    let url: URL
    let match: TextMatch

    init(url: URL, match: TextMatch) {
        self.url = url
        self.match = match
    }
}

/// The results: Return opens the selected row, Command-Return in a new tab, and Escape leaves the search.
private final class ResultsOutlineView: NSOutlineView {
    var opens: (_ row: Int, _ newTab: Bool) -> Void = { _, _ in }
    var closes: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: opens(selectedRow, event.modifierFlags.contains(.command))
        case 53: closes()
        default: super.keyDown(with: event)
        }
    }
}

/// A file's row: its name, the folder it is in and how many matches it holds.
private final class FileResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("searchFile")

    private let folder = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView = icon
        textField = name
        for view in [icon, name, folder, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            folder.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            folder.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            count.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("FileResultCell is built in code")
    }

    func show(_ name: String, in path: String, count matches: Int) {
        textField?.stringValue = name
        folder.stringValue = path
        count.stringValue = matches.formatted()
        let label = [name, path, "\(matches.formatted()) \(matches == 1 ? "match" : "matches")"].filter { !$0.isEmpty }
        setAccessibilityLabel(label.joined(separator: ", "))
    }
}

/// A match's row: its line number, then the line with the match on the theme's find highlight. The line is not the
/// cell's `textField`, which a source list restyles, dropping the highlight.
private final class LineResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("searchLine")

    private let number = NSTextField(labelWithString: "")
    private let line = NSTextField(labelWithString: "")
    private var match: TextMatch?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        number.textColor = .tertiaryLabelColor
        number.alignment = .right
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [number, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor),
            number.widthAnchor.constraint(equalToConstant: 30),
            number.firstBaselineAnchor.constraint(equalTo: line.firstBaselineAnchor),
            line.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LineResultCell is built in code")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    func show(_ match: TextMatch) {
        self.match = match
        number.stringValue = String(match.line)
        render()
        setAccessibilityLabel("Line \(match.line): \(match.preview)")
    }

    /// On a selected row the line takes the selection's text color and the match a lighter wash of it.
    private func render() {
        guard let match else { return }
        let selected = backgroundStyle == .emphasized
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let ink = selected ? NSColor.alternateSelectedControlTextColor : .labelColor
        let text = NSMutableAttributedString(string: match.preview, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink, .paragraphStyle: style,
        ])
        text.addAttribute(.backgroundColor, value: selected ? ink.withAlphaComponent(0.25) : Self.findMatch, range: match.previewRange)
        line.attributedStringValue = text
    }

    /// The theme's accent at 25%, or 35% in dark (synthesis 2.1).
    private static var findMatch: NSColor {
        let accent = ThemeStore.shared.color(.accent)
        return NSColor(name: nil) { accent.withAlphaComponent($0.isDark ? 0.35 : 0.25) }
    }
}
