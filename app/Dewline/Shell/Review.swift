import AppKit
import MdCore

/// Review Changes, Follow Changes and the "finished" line: the agents' marked changes across a window's open files.
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
        guard let window else { return [] }
        return (window.tabGroup?.windows ?? [window]).compactMap { ($0.windowController?.document as? MarkdownDocument)?.live }
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

    /// A session's turn ended: each window holding its changes shows the finished line. The landing its last write
    /// started gets 500 ms to arrive first.
    static func finished(vendor: ControlSocket.Claim.Vendor, session: String) {
        let vendor: ChangeEngine.Vendor = switch vendor {
        case .claude: .claude
        case .codex: .codex
        case .cursor: .cursor
        }
        let origin = ChangeEngine.Origin.agent(vendor, session: session)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            for window in NSApp.windows {
                (window.windowController as? MainWindowController)?.finished.show(origin)
            }
        }
    }
}

/// "Claude finished · 3 places in 2 files · Review", one quiet line under the tab bar when an agent's turn ends with
/// changes waiting in this window. It leaves when they are decided or Review Changes opens. No sound, no notification.
@MainActor
final class FinishedLine: NSView {
    static let height: CGFloat = 24
    private let label = NSTextField(labelWithString: "")
    private let review = NSButton(title: "Review", target: nil, action: #selector(ReviewPanel.showReview(_:)))
    private var origin: ChangeEngine.Origin?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        review.isBordered = false
        review.font = .systemFont(ofSize: 12, weight: .medium)
        review.target = ReviewPanel.shared
        review.toolTip = "Review Changes (⇧⌘R)"
        let row = NSStackView(views: [label, review])
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(recount), name: LiveFile.changesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("FinishedLine is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ThemeStore.shared.color(.paper).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeDidChange()
    }

    @objc private func themeDidChange() {
        label.textColor = ThemeStore.shared.color(.ink2)
        review.contentTintColor = ThemeStore.shared.color(.accent)
        needsDisplay = true
    }

    func show(_ origin: ChangeEngine.Origin) {
        self.origin = origin
        recount()
    }

    func dismiss() {
        origin = nil
        isHidden = true
    }

    @objc private func recount() {
        guard let origin else { return }
        let (places, files) = Review.count(origin, in: Review.files(in: window))
        guard places > 0 else { return dismiss() }
        let noun = places == 1 ? "place" : "places"
        label.stringValue = "\(MarkWriter(origin).name) finished · \(places) \(noun) in \(files) \(files == 1 ? "file" : "files") · "
        setAccessibilityLabel(label.stringValue + "Review")
        isHidden = false
    }
}

/// Review Changes (Shift-Cmd-R): every undecided marked change in the main window's open files, by writer session,
/// then file, then change. A click jumps to the change; Keep and Revert decide one, and with Option every change of
/// its session.
@MainActor
final class ReviewPanel: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let shared = ReviewPanel()

    final class Node {
        enum Kind {
            case session(ChangeEngine.Origin)
            case file(LiveFile)
            case change(LiveFile, UInt64)
        }

        let kind: Kind
        var children: [Node] = []

        init(_ kind: Kind) {
            self.kind = kind
        }

        var count: Int {
            if case .change = kind { return 1 }
            return children.reduce(0) { $0 + $1.count }
        }
    }

    private var roots: [Node] = []
    private var files: [LiveFile] = []
    private var reloading = false
    private lazy var outline = NSOutlineView()
    private lazy var empty = NSTextField(labelWithString: "All changes reviewed")
    private lazy var panel: NSPanel = makePanel()

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReload), name: LiveFile.changesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReload), name: NSWindow.didBecomeMainNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReload), name: MarkdownDocument.didCloseNotification, object: nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: true)
        panel.title = "Review Changes"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 200)
        panel.setFrameAutosaveName("Review Changes")

        let column = NSTableColumn(identifier: .init("Change"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.usesAutomaticRowHeights = false
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.setAccessibilityLabel("Changes")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        let content = NSVisualEffectView()
        content.material = .sidebar
        for view in [scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        if let main = NSApp.mainWindow, !panel.setFrameUsingName("Review Changes") {
            panel.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX - 376, y: main.frame.maxY - 72))
        }
        return panel
    }

    /// Shift-Cmd-R: shows the panel, or hides it when it is in front.
    @objc func toggleReview(_ sender: Any?) {
        if panel.isVisible { return panel.orderOut(sender) }
        showReview(sender)
    }

    /// The finished line's Review.
    @objc func showReview(_ sender: Any?) {
        for window in NSApp.windows { (window.windowController as? MainWindowController)?.finished.dismiss() }
        reload()
        panel.orderFront(sender)
    }

    /// View > Follow Changes.
    @objc func toggleFollow(_ sender: Any?) {
        Review.follows.toggle()
    }

    @objc private func scheduleReload() {
        guard panel.isVisible, !reloading else { return }
        reloading = true
        DispatchQueue.main.async { [weak self] in
            self?.reloading = false
            self?.reload()
        }
    }

    private func reload() {
        files = Review.files(in: NSApp.mainWindow)
        var sessions: [String: Node] = [:]
        for live in files.sorted(by: { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }) {
            var byFile: [String: Node] = [:]
            for (id, change) in live.changes.filter(\.value.marked).sorted(by: { $0.value.range.location < $1.value.range.location }) {
                let key = Review.key(change.origin)
                let session = sessions[key] ?? Node(.session(change.origin))
                sessions[key] = session
                let file = byFile[key] ?? {
                    let file = Node(.file(live))
                    session.children.append(file)
                    return file
                }()
                byFile[key] = file
                file.children.append(Node(.change(live, id)))
            }
        }
        roots = sessions.sorted { $0.key < $1.key }.map(\.value)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        empty.isHidden = !roots.isEmpty
    }

    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        switch node.kind {
        case .change(let live, let id): live.reveal(id, caret: true)
        case .file:
            if case .change(let live, let id) = node.children.first?.kind { live.reveal(id, caret: true) }
        case .session: break
        }
    }

    /// Keep or Revert on a change's row; with Option, every change of its session in this window.
    fileprivate func decide(_ live: LiveFile, _ id: UInt64, keep: Bool) {
        var targets = [(live, id)]
        if NSEvent.modifierFlags.contains(.option), let origin = live.changes[id]?.origin {
            let key = Review.key(origin)
            targets = files.flatMap { file in
                file.changes.filter { $0.value.marked && Review.key($0.value.origin) == key }.keys.map { (file, $0) }
            }
        }
        for (file, id) in targets {
            keep ? file.keep(id) : file.revert(id)
        }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .change = (item as? Node)?.kind { return 28 }
        return 24
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.kind {
        case .session(let origin):
            let writer = MarkWriter(origin)
            let title = NSMutableAttributedString(attributedString: writer.stamp)
            if case .agent(_, let session) = origin {
                title.append(NSAttributedString(string: "  " + session.prefix(8), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            return ReviewRow(title: title, detail: "\(node.count)", symbol: nil)
        case .file(let live):
            let name = NSAttributedString(string: live.url.lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            return ReviewRow(title: name, detail: "\(node.count)", symbol: "doc.text")
        case .change(let live, let id):
            let excerpt = live.excerpt(id)
            let conflict = live.changes[id]?.conflict == true
            let text = NSAttributedString(string: conflict ? "Two versions: \(excerpt)" : excerpt.isEmpty ? "Blank lines" : excerpt, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
            ])
            let row = ReviewRow(title: text, detail: "\(live.line(id))", symbol: nil)
            row.addDecisions(
                keep: { [weak self, weak live] in if let live { self?.decide(live, id, keep: true) } },
                revert: { [weak self, weak live] in if let live { self?.decide(live, id, keep: false) } })
            row.toolTip = "Line \(live.line(id)). Option-click Keep or Revert for every change in this session."
            return row
        }
    }
}

extension ReviewPanel: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFollow(_:)) { menuItem.state = Review.follows ? .on : .off }
        if menuItem.action == #selector(toggleReview(_:)) { menuItem.state = panel.isVisible ? .on : .off }
        return true
    }
}

/// A row of Review Changes: a title, a count or line number in tabular digits, and Keep and Revert on a change.
private final class ReviewRow: NSTableCellView {
    private let stack = NSStackView()
    private var actions: [() -> Void] = []

    init(title: NSAttributedString, detail: String, symbol: String?) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .secondaryLabelColor
            stack.addArrangedSubview(icon)
        }
        let label = NSTextField(labelWithAttributedString: title)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(label)
        let count = NSTextField(labelWithString: detail)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(count)
    }

    required init?(coder: NSCoder) {
        fatalError("ReviewRow is built in code")
    }

    func addDecisions(keep: @escaping () -> Void, revert: @escaping () -> Void) {
        for (index, (title, action)) in [("Keep", keep), ("Revert", revert)].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(decide(_:)))
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.tag = index
            button.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(button)
            actions.append(action)
        }
    }

    @objc private func decide(_ sender: NSButton) {
        actions[sender.tag]()
    }
}
