import AppKit
import MdCore

/// The Changes tab and Follow Changes: the marked changes in a window's open notes, and the notes changed while closed.
@MainActor
enum Review {
    private static let followKey = "FollowChanges"
    private static var following: (live: LiveFile, change: UInt64)?

    /// Follow Changes: while you are idle, each new marked landing scrolls into view.
    static var follows: Bool {
        get { UserDefaults.standard.bool(forKey: followKey) }
        set { UserDefaults.standard.set(newValue, forKey: followKey) }
    }

    /// The window's tabs' files.
    static func files(in window: NSWindow?) -> [LiveFile] {
        documents(in: window).compactMap(\.live)
    }

    /// The window's tabs' notes.
    static func documents(in window: NSWindow?) -> [MarkdownDocument] {
        guard let window else { return [] }
        let windows = (window.windowController as? MainWindowController)?.tabs.tabs.compactMap(\.window) ?? [window]
        return windows.compactMap { $0.windowController?.document as? MarkdownDocument }
    }

    /// Groups changes by writer session: "claude:<id>", "git", "external".
    static func key(_ origin: ChangeEngine.Origin) -> String {
        switch origin {
        case .agent(let vendor, let session): "\(vendor):\(session)"
        case .git: "git"
        case .external: "external"
        case .user: "user"
        case .collaborator(let peer, _): "collab:\(peer)"
        }
    }

    /// The undecided marked changes in `files` from `origin`'s session, as places and files.
    static func count(_ origin: ChangeEngine.Origin, in files: [LiveFile]) -> (places: Int, files: Int) {
        let key = key(origin)
        let counts = files.map { $0.changes.values.count { $0.marked && Self.key($0.origin) == key } }
        return (counts.reduce(0, +), counts.count { $0 > 0 })
    }

    /// A marked change landed; Follow Changes scrolls to it once you have not typed for 5 s.
    static func landed(_ live: LiveFile, _ change: UInt64) {
        if let origin = live.changes[change]?.origin { times[key(origin)] = Date() }
        guard follows, ContinuousClock.now - LiveFile.lastEdit >= .seconds(5) else { return }
        // A landing's relabels arrive together; the last one is followed.
        let waiting = following != nil
        following = (live, change)
        guard !waiting else { return }
        DispatchQueue.main.async {
            guard let (live, change) = following else { return }
            following = nil
            live.reveal(change, caret: false)
        }
    }

    /// Next Change and Previous Change: reveals the marked change after or before the caret, then the first or last
    /// one in each of the window's other tabs in order, wrapping back to `textView`'s file.
    static func step(from textView: EditorTextView, forward: Bool) {
        guard let live = textView.marks.live else { return }
        let files = files(in: textView.window)
        let caret = textView.selectedRange().location
        func marked(_ file: LiveFile) -> [UInt64] {
            file.changes.filter(\.value.marked).sorted { $0.value.range.location < $1.value.range.location }.map(\.key)
        }
        let here = marked(live)
        let ahead = here.filter { id in
            let at = live.changes[id]!.range.location
            return forward ? at > caret : at < caret
        }
        if let id = forward ? ahead.first : ahead.last { return live.reveal(id, caret: true) }
        let start = files.firstIndex { $0 === live } ?? 0
        for offset in 1..<max(files.count, 1) {
            let file = files[(start + (forward ? offset : files.count - offset)) % files.count]
            let ids = marked(file)
            if let id = forward ? ids.first : ids.last { return file.reveal(id, caret: true) }
        }
        if let id = forward ? here.first : here.last { live.reveal(id, caret: true) }
    }

    /// Whether any of the window's tabs holds a marked change.
    static func hasMarked(in window: NSWindow?) -> Bool {
        files(in: window).contains { $0.changes.values.contains(where: \.marked) }
    }

    /// When each writer session's turn last ended, or its last change landed, for "Claude Code · 2:36 PM".
    private static var times: [String: Date] = [:]

    /// A session's turn ended; the Changes tab dates its notes by it.
    static func finished(vendor: ControlSocket.Claim.Vendor, session: String) {
        times["\(vendor.rawValue):\(session)"] = Date()
    }

    /// When `origin`'s session last finished a turn or landed a change.
    static func time(of origin: ChangeEngine.Origin) -> Date? {
        times[key(origin)]
    }

    /// The notes changed while closed, newest first, which the Keep bar counts and the Changes tab lists.
    static var closedNotes: () -> [ClosedNote] = { [] }

    static var closedCount: Int {
        closedNotes().count
    }

    /// "Claude Code · 2:36 PM", or the name alone with no time known.
    static func byline(_ origin: ChangeEngine.Origin, at time: Date?) -> String {
        let name = EarlierVersions.writer(origin)
        return time.map { "\(name) \u{00B7} \($0.formatted(date: .omitted, time: .shortened))" } ?? name
    }
}

/// A note an outside writer changed while it was closed.
struct ClosedNote: Equatable {
    let url: URL
    let origin: ChangeEngine.Origin
    let time: Date
}


/// The right pane's Changes tab: the window's open notes with undecided changes, then "Changed while closed". A note
/// heads its changes with "Claude Code · 2:36 PM"; each row is the changed line, its changed words in bold, and
/// "line 17". Keep and Revert show on the selected or hovered row; with Option they decide the whole note.
@MainActor
final class ReviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Row {
        case note(LiveFile, String)
        case change(LiveFile, UInt64, NSString?)
        case closedHeading
        case closed(ClosedNote)
    }

    private(set) var rows: [Row] = []
    private weak var source: NSWindow?
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "Nothing to review.")
    private var reloading = false
    private var flags: Any?
    private(set) var optionDown = false

    /// Lists `window`'s notes, or the notes of the window this tab is in.
    init(for window: NSWindow? = nil) {
        source = window
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ReviewViewController is built in code")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("Change"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Changes")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.font = .systemFont(ofSize: 13)
        empty.alignment = .center
        let root = NSView()
        for view in [scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        for name in [LiveFile.changesDidChange, NSWindow.didBecomeMainNotification, MarkdownDocument.didCloseNotification, ThemeStore.didChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleReload), name: name, object: nil)
        }
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
        flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.setOption(event.modifierFlags.contains(.option)) }
            return event
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let flags { NSEvent.removeMonitor(flags) }
        flags = nil
    }

    /// With Option down, Keep and Revert read "Keep All in Note" and "Revert All in Note".
    func setOption(_ down: Bool) {
        guard down != optionDown else { return }
        optionDown = down
        table.enumerateAvailableRowViews { row, _ in (row.view(atColumn: 0) as? ChangeRow)?.optionDown = down }
    }

    @objc private func scheduleReload() {
        guard !reloading else { return }
        reloading = true
        DispatchQueue.main.async { [weak self] in
            self?.reloading = false
            self?.reload()
        }
    }

    func reload() {
        let documents = Review.documents(in: source ?? view.window)
        let files = documents.compactMap(\.live)
        rows = []
        for document in documents {
            guard let live = document.live else { continue }
            let text = document.textView?.string as NSString?
            let marked = live.changes.filter(\.value.marked).sorted { $0.value.range.location < $1.value.range.location }
            guard let newest = marked.max(by: { (Review.time(of: $0.value.origin) ?? .distantPast) < (Review.time(of: $1.value.origin) ?? .distantPast) }) else {
                continue
            }
            rows.append(.note(live, Review.byline(newest.value.origin, at: Review.time(of: newest.value.origin))))
            rows += marked.map { .change(live, $0.key, text) }
        }
        let open = Set(files.map(\.url.standardizedFileURL))
        let closed = Review.closedNotes().filter { !open.contains($0.url.standardizedFileURL) }
        if !closed.isEmpty { rows += [.closedHeading] + closed.map(Row.closed) }
        empty.textColor = ThemeStore.shared.color(.ink2)
        empty.isHidden = !rows.isEmpty
        table.reloadData()
    }

    @objc private func clicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        switch rows[table.clickedRow] {
        case .change(let live, let id, _): live.reveal(id, caret: true)
        case .note(let live, _):
            if let first = live.changes.filter(\.value.marked).min(by: { $0.value.range.location < $1.value.range.location }) {
                live.reveal(first.key, caret: true)
            }
        case .closed(let note):
            NSDocumentController.shared.openDocument(withContentsOf: note.url, display: true) { _, _, _ in }
        case .closedHeading: break
        }
        table.enumerateAvailableRowViews { row, index in (row.view(atColumn: 0) as? ChangeRow)?.selected = index == table.clickedRow }
    }

    /// Keep or Revert on a row; with Option, every change in its note.
    func decide(_ live: LiveFile, _ id: UInt64, keep: Bool) {
        if optionDown { return live.decideAll(keep: keep) }
        keep ? live.keep(id) : live.revert(id)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .note, .closedHeading: 36
        case .change, .closed: 32
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let store = ThemeStore.shared
        switch rows[row] {
        case .note(let live, let byline):
            return HeadingRow(live.url.deletingPathExtension().lastPathComponent, detail: byline)
        case .closedHeading:
            return HeadingRow("Changed while closed", detail: nil)
        case .closed(let note):
            let title = NSAttributedString(string: note.url.deletingPathExtension().lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: store.color(.ink),
            ])
            return ChangeRow(title, detail: Review.byline(note.origin, at: note.time), decide: nil)
        case .change(let live, let id, let text):
            let row = ChangeRow(Self.line(of: id, in: live, text: text), detail: "line \(live.line(id))") { [weak self, weak live] keep in
                guard let live else { return }
                self?.decide(live, id, keep: keep)
            }
            row.optionDown = optionDown
            return row
        }
    }

    /// The change's whole line, trimmed, with the changed words in bold; a change that only removed text shows the
    /// line with the removed words struck.
    static func line(of id: UInt64, in live: LiveFile, text: NSString?) -> NSAttributedString {
        let store = ThemeStore.shared
        let regular: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: store.color(.ink)]
        guard let change = live.changes[id], let text else { return NSAttributedString(string: live.excerpt(id), attributes: regular) }
        let range = NSIntersectionRange(change.range, NSRange(location: 0, length: text.length))
        var line = text.lineRange(for: NSRange(location: range.location, length: 0))
        if range.length > 0, !text.substring(with: line).contains(where: { !$0.isWhitespace }) {
            line = text.lineRange(for: NSRange(location: min(range.location + 1, max(text.length - 1, 0)), length: 0))
        }
        let shown = NSMutableAttributedString(string: text.substring(with: line), attributes: regular)
        let local = NSIntersectionRange(NSRange(location: range.location - line.location, length: range.length), NSRange(location: 0, length: shown.length))
        if local.length > 0 {
            shown.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: local)
        } else if change.conflict || !change.removed.isEmpty {
            let removed = (change.conflict ? change.theirs : change.removed).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            shown.insert(NSAttributedString(string: removed, attributes: regular.merging([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: store.color(.ink2),
            ]) { $1 }), at: min(max(range.location - line.location, 0), shown.length))
        }
        let trimmed = shown.string
        let lead = trimmed.prefix { $0.isWhitespace }.utf16.count
        let tail = String(trimmed.reversed().prefix { $0.isWhitespace }).utf16.count
        guard lead + tail < shown.length else { return NSAttributedString(string: "Blank lines", attributes: regular) }
        return shown.attributedSubstring(from: NSRange(location: lead, length: shown.length - lead - tail))
    }
}

/// A note's name in 13 pt semibold over its byline, or the "Changed while closed" heading.
private final class HeadingRow: NSTableCellView {
    init(_ title: String, detail: String?) {
        super.init(frame: .zero)
        let store = ThemeStore.shared
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = store.color(.ink)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name])
        row.spacing = 8
        if let detail {
            let byline = NSTextField(labelWithString: detail)
            byline.font = .systemFont(ofSize: 11)
            byline.textColor = store.color(.ink2)
            row.addArrangedSubview(byline)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityLabel([title, detail].compactMap(\.self).joined(separator: ", "))
    }

    required init?(coder: NSCoder) {
        fatalError("HeadingRow is built in code")
    }
}

/// A change's line and "line 17", with Keep and Revert in place of the line number while the row is hovered or
/// selected. A closed note's row has no decisions.
final class ChangeRow: NSTableCellView {
    private let detail: NSTextField
    private let keep: FlowButton
    private let revert: FlowButton
    private let decides: Bool
    private var hovering = false {
        didSet { update() }
    }
    var selected = false {
        didSet { update() }
    }
    var optionDown = false {
        didSet {
            keep.title = optionDown ? "Keep All in Note" : "Keep"
            revert.title = optionDown ? "Revert All in Note" : "Revert"
        }
    }

    init(_ title: NSAttributedString, detail text: String, decide: ((Bool) -> Void)?) {
        detail = NSTextField(labelWithString: text)
        keep = FlowButton("Keep", style: .plain) { decide?(true) }
        revert = FlowButton("Revert", style: .plain) { decide?(false) }
        decides = decide != nil
        super.init(frame: .zero)
        let label = NSTextField(labelWithAttributedString: title)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = ThemeStore.shared.color(.ink2)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        keep.toolTip = "Keep (\u{2318}\u{21A9}). Option: every change in this note."
        revert.toolTip = "Revert (\u{2325}\u{2318}\u{232B}). Option: every change in this note."
        let row = NSStackView(views: [label, detail, revert, keep])
        row.spacing = 4
        row.setCustomSpacing(8, after: label)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityLabel("\(title.string), \(text)")
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("ChangeRow is built in code")
    }

    /// Whether Keep and Revert show.
    var showsDecisions: Bool {
        !keep.isHidden
    }

    private func update() {
        let decisions = decides && (hovering || selected)
        keep.isHidden = !decisions
        revert.isHidden = !decisions
        detail.isHidden = decisions
        wantsLayer = true
        layer?.backgroundColor = hovering || selected ? FlowColors.selection.resolved(for: effectiveAppearance).cgColor : nil
        layer?.cornerRadius = 6
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }
}

/// View > Follow Changes: while you are idle, each new marked change scrolls into view.
@MainActor
final class FollowChanges: NSObject, NSMenuItemValidation {
    static let shared = FollowChanges()

    @objc func toggleFollow(_ sender: Any?) {
        Review.follows.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = Review.follows ? .on : .off
        return true
    }
}
