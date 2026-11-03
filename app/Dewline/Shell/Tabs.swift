import AppKit

/// One window's tabs, which Dewline draws itself. Each tab keeps its own controller and window, so its document,
/// sheets and undo stay as they are; only the selected tab's window is on screen, and the others wait ordered out at
/// the same frame. Posts `changed` when a tab comes, goes, is selected, or its name or marks change.
@MainActor
final class TabSet {
    static let changed = Notification.Name("DewlineTabsChanged")

    private(set) var tabs: [MainWindowController] = []
    private(set) weak var selected: MainWindowController?

    init(_ first: MainWindowController) {
        tabs = [first]
        selected = first
    }

    /// Adds `tab` after `neighbor`, or last.
    func insert(_ tab: MainWindowController, after neighbor: MainWindowController?) {
        let index = neighbor.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        post()
    }

    /// Puts `tab`'s window where the selected one is and orders the selected one out. The caller brings `tab` front.
    func select(_ tab: MainWindowController) {
        guard let old = selected, old !== tab, tabs.contains(tab), let window = tab.window, let leaving = old.window else {
            selected = tab
            return
        }
        if leaving.isVisible || leaving.isMiniaturized {
            window.setFrame(leaving.frame, display: false)
        }
        selected = tab
        tab.adoptPane(from: old)
        window.isExcludedFromWindowsMenu = false
        leaving.isExcludedFromWindowsMenu = true
        // The window goes after the new one is in front, so the screen never shows neither.
        Task { @MainActor in
            if self.selected !== old { leaving.orderOut(nil) }
        }
        post()
    }

    /// Takes a closing tab out; when it was the selected one, its neighbor takes its place.
    func remove(_ tab: MainWindowController) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if selected === tab || selected == nil, !tabs.isEmpty {
            let next = tabs[min(index, tabs.count - 1)]
            selected = next
            if let frame = tab.window?.frame { next.window?.setFrame(frame, display: false) }
            next.window?.isExcludedFromWindowsMenu = false
            next.showWindow(nil)
        }
        post()
    }

    /// The tab `offset` places from the selected one, wrapping around.
    func tab(_ offset: Int) -> MainWindowController? {
        guard let selected, let index = tabs.firstIndex(of: selected), tabs.count > 1 else { return nil }
        return tabs[((index + offset) % tabs.count + tabs.count) % tabs.count]
    }

    func post() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

/// The tab row along the top of the editor column, 30 pt, shown with two tabs or more: each tab 120 to 220 pt wide.
/// The selected tab takes the page's paper and joins it, its name in `ink` 13 medium; the others sit on the chrome in
/// `ink2`. A tab in back shows an accent dot while outside changes in it wait. The close glyph shows under the pointer.
final class TabRow: NSView {
    static let height: CGFloat = 30

    weak var tabs: TabSet? {
        didSet {
            NotificationCenter.default.removeObserver(self, name: TabSet.changed, object: nil)
            if let tabs { NotificationCenter.default.addObserver(self, selector: #selector(reload), name: TabSet.changed, object: tabs) }
            reload()
        }
    }

    private let stack = NSStackView()
    /// Each tab's dot as the row last showed it.
    private var dots: [NSColor?] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .bottom
        stack.translatesAutoresizingMaskIntoConstraints = false
        let rule = RuleLine()
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ThemeStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changesChanged), name: LiveFile.changesDidChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TabRow is built in code")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.color(.chrome).resolved(for: effectiveAppearance).cgColor
    }

    @objc func reload() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        dots = tabs?.tabs.map(\.tabDot) ?? []
        needsDisplay = true
        guard let tabs else { return }
        for tab in tabs.tabs {
            let selected = tab === tabs.selected
            stack.addArrangedSubview(TabButton(tab, selected: selected, dot: selected ? nil : tab.tabDot))
        }
    }

    /// Each keystroke before a pending change moves it; the row rebuilds only when a tab's dot changes.
    @objc private func changesChanged() {
        guard tabs?.tabs.map(\.tabDot) ?? [] != dots else { return }
        reload()
    }
}

/// One tab: its name, a dot for outside changes waiting in a tab in back, and a close glyph under the pointer.
private final class TabButton: NSView {
    private weak var tab: MainWindowController?
    private let selected: Bool
    private let name: String
    private let dot: NSColor?
    private let close = GlyphButton(.close, label: "Close Tab", target: nil, action: nil)
    private var hovering = false {
        didSet { close.isHidden = !hovering }
    }

    init(_ tab: MainWindowController, selected: Bool, dot: NSColor?) {
        self.tab = tab
        self.selected = selected
        name = tab.tabName
        self.dot = dot
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        close.target = self
        close.action = #selector(closeTab)
        close.isHidden = true
        addSubview(close)
        let text = ceil((name as NSString).size(withAttributes: [.font: Self.font(selected)]).width)
        let width = min(max(text + (dot == nil ? 0 : 11) + 24 + 24, 120), 220)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: selected ? TabRow.height : TabRow.height - 1),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(name)
        setAccessibilityValue(selected)
    }

    required init?(coder: NSCoder) {
        fatalError("TabButton is built in code")
    }

    private static func font(_ selected: Bool) -> NSFont {
        selected ? Chrome.labelActive : Chrome.label
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            Chrome.color(.paper).setFill()
            bounds.fill()
            Chrome.color(.rule).setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font(selected), .foregroundColor: Chrome.color(selected ? .ink : .ink2)]
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingMiddle
        let string = NSAttributedString(string: name, attributes: attributes.merging([.paragraphStyle: line]) { $1 })
        let size = string.size()
        let room = bounds.width - 24 - 24 - (dot == nil ? 0 : 11)
        string.draw(with: NSRect(x: 12, y: bounds.midY - ceil(size.height) / 2, width: room, height: ceil(size.height)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let dot {
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12 + min(ceil(size.width), room) + 6, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        tab?.showWindow(nil)
    }

    override func accessibilityPerformPress() -> Bool {
        tab?.showWindow(nil)
        return true
    }

    /// A tab closes as its window would; a tab in back comes forward first.
    @objc private func closeTab() {
        guard let tab else { return }
        tab.showWindow(nil)
        tab.window?.performClose(nil)
    }
}
