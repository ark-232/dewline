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
            next.window?.makeKeyAndOrderFront(nil)
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

/// The tab row along the top of the editor island, 34 pt: each tab sized to its name, at most 200 pt, Bricolage 13,
/// the selected one in `ink` and the rest in `ink3`, with no backgrounds or separators. A tab's dot shows an agent's
/// pending changes in the writer's color, or unsaved edits in `ink2`. The close glyph shows under the pointer. The
/// horizon runs along the row's bottom edge.
final class TabRow: NSView {
    static let height: CGFloat = 34

    weak var tabs: TabSet? {
        didSet {
            NotificationCenter.default.removeObserver(self, name: TabSet.changed, object: nil)
            if let tabs { NotificationCenter.default.addObserver(self, selector: #selector(reload), name: TabSet.changed, object: tabs) }
            reload()
        }
    }

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        for name in [ThemeStore.didChange, LiveFile.changesDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("TabRow is built in code")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc func reload() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        guard let tabs else { return }
        for tab in tabs.tabs {
            stack.addArrangedSubview(TabButton(tab, selected: tab === tabs.selected))
        }
    }
}

/// One tab: its name, a dot for pending changes or unsaved edits, and a close glyph under the pointer.
private final class TabButton: NSView {
    private weak var tab: MainWindowController?
    private let selected: Bool
    private let name: String
    private let dot: NSColor?
    private let close = GlyphButton(.close, label: "Close Tab", target: nil, action: nil)
    private var hovering = false {
        didSet { close.isHidden = !hovering }
    }

    init(_ tab: MainWindowController, selected: Bool) {
        self.tab = tab
        self.selected = selected
        name = tab.tabName
        dot = tab.tabDot
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        close.target = self
        close.action = #selector(closeTab)
        close.isHidden = true
        addSubview(close)
        let text = ceil((name as NSString).size(withAttributes: [.font: Self.font(selected)]).width)
        let width = min(text + (dot == nil ? 0 : 11) + 24 + 20, 200)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: TabRow.height),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
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

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font(selected), .foregroundColor: Chrome.color(selected ? .ink : .ink3)]
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingMiddle
        let string = NSAttributedString(string: name, attributes: attributes.merging([.paragraphStyle: line]) { $1 })
        let size = string.size()
        let room = bounds.width - 24 - (dot == nil ? 0 : 11)
        string.draw(with: NSRect(x: 0, y: bounds.midY - ceil(size.height) / 2, width: room, height: ceil(size.height)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let dot {
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: min(ceil(size.width), room) + 6, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
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

    /// A tab closes as its window would, asking first about unsaved edits; a tab in back comes forward to ask.
    @objc private func closeTab() {
        guard let tab else { return }
        tab.showWindow(nil)
        tab.window?.performClose(nil)
    }
}
