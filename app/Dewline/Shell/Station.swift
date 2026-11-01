import AppKit

/// The window's frame: the theme's `frame` color behind the title band and the islands. A drag on it moves the
/// window, and a double-click does what the system's title bar setting says.
final class FrameView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FrameView is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.color(.frame).resolved(for: effectiveAppearance).cgColor
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        Self.titleBarClick(event, in: window)
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }

    /// A drag moves the window; a double-click zooms or minimizes it, or does nothing, as System Settings has it.
    static func titleBarClick(_ event: NSEvent, in window: NSWindow?) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}

/// A rounded surface on the frame: 10 pt corners, a 1 px `strokeSubtle` edge, no shadow. Depth comes from the step
/// between the island's fill and the frame.
class IslandView: NSView {
    let fill: Token

    init(_ fill: Token) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(islandThemeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("IslandView is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        IslandView.paint(layer, fill: fill, in: self)
    }

    /// Paints `layer` as an island in `view`'s appearance.
    static func paint(_ layer: CALayer?, fill: Token, in view: NSView) {
        guard let layer else { return }
        let appearance = view.effectiveAppearance
        layer.backgroundColor = Chrome.color(fill).resolved(for: appearance).cgColor
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1 / (view.window?.backingScaleFactor ?? 2)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer.borderColor = (contrast ? Chrome.color(.ink3) : Chrome.strokeSubtle).resolved(for: appearance).cgColor
    }

    @objc private func islandThemeDidChange() {
        needsDisplay = true
    }
}

/// The split between the islands: a 5 pt gap where the frame shows through.
final class StationSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 5 }

    override func drawDivider(in rect: NSRect) {}
}

/// The main window's split, with a sidebar that is a plain item, so no system sidebar glass draws under it. Show
/// Sidebar collapses and expands it.
final class StationSplitController: NSSplitViewController {
    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        let split = StationSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
    }

    required init?(coder: NSCoder) {
        fatalError("StationSplitController is built in code")
    }

    private var sidebarItem: NSSplitViewItem? { splitViewItems.first }

    override func toggleSidebar(_ sender: Any?) {
        guard let item = sidebarItem else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            item.isCollapsed.toggle()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                item.animator().isCollapsed.toggle()
            }
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) {
            (item as? NSMenuItem)?.title = sidebarItem?.isCollapsed == false ? "Hide Sidebar" : "Show Sidebar"
            return sidebarItem != nil
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// The 40 pt band along the window's top, on the frame: past the traffic lights, the sidebar toggle and back and
/// forward as bare glyphs; over the editor island, the dew-line mark, the `dewline` wordmark and the path to the open
/// file; at the right, who is here and Share. Its row centers on the traffic lights, which stay where macOS puts them.
final class TitleBand: NSView {
    static let height: CGFloat = 40
    /// The corner the traffic lights keep, outside full screen.
    static let trafficLights: CGFloat = 78

    let toggle: GlyphButton
    let back: GlyphButton
    let forward: GlyphButton
    let share: GlyphButton
    /// A crumb was clicked: its index in the path, and the crumb, to show a menu under.
    var crumbClicked: (Int, NSView) -> Void = { _, _ in }

    private let mark = DewMark()
    private let wordmark = NSTextField(labelWithString: "")
    private let crumbs = NSStackView()
    private let dirty = Dot(diameter: 5)
    private let people = NSStackView()
    private var reserve: NSLayoutConstraint!
    private var center: NSLayoutConstraint!
    private var path: [String] = []
    private var writers: [(initials: String, writer: Writer)] = []

    init(sidebarToggle: Any?) {
        toggle = GlyphButton(.sidebar, label: "Show or hide the sidebar", target: sidebarToggle as AnyObject?, action: #selector(NSSplitViewController.toggleSidebar(_:)))
        back = GlyphButton(.back, label: "Back", target: nil, action: #selector(MainWindowController.goBack(_:)))
        forward = GlyphButton(.forward, label: "Forward", target: nil, action: #selector(MainWindowController.goForward(_:)))
        share = GlyphButton(.share, label: "Edit this file live with someone", target: nil, action: #selector(MainWindowController.shareDocument(_:)))
        super.init(frame: .zero)
        wordmark.setAccessibilityLabel("Dewline")
        wordmark.isSelectable = false
        crumbs.spacing = 6
        crumbs.setHuggingPriority(.defaultLow, for: .horizontal)
        crumbs.setClippingResistancePriority(.defaultLow, for: .horizontal)
        people.spacing = -4
        let nav = NSStackView(views: [toggle, back, forward])
        nav.spacing = 2
        nav.setCustomSpacing(10, after: toggle)
        let brand = NSStackView(views: [mark, wordmark, crumbs, dirty])
        brand.spacing = 8
        brand.setCustomSpacing(6, after: mark)
        brand.setCustomSpacing(10, after: wordmark)
        brand.setHuggingPriority(.defaultLow, for: .horizontal)
        brand.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let right = NSStackView(views: [people, share])
        right.spacing = 12
        for view in [nav, brand, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        reserve = nav.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trafficLights)
        center = nav.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.height / 2)
        brandLeading = brand.leadingAnchor.constraint(equalTo: nav.trailingAnchor, constant: 18)
        brandLeading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            reserve, center, brandLeading,
            heightAnchor.constraint(equalToConstant: Self.height),
            brand.leadingAnchor.constraint(greaterThanOrEqualTo: nav.trailingAnchor, constant: 18),
            brand.centerYAnchor.constraint(equalTo: nav.centerYAnchor),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: nav.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("TitleBand is built in code")
    }

    private var brandLeading: NSLayoutConstraint!
    private var islandAlignment: NSLayoutConstraint?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        FrameView.titleBarClick(event, in: window)
    }

    /// Lines the mark up with the editor island's leading edge while the sidebar leaves room for it.
    func align(with editor: NSView) {
        islandAlignment?.isActive = false
        let alignment = mark.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 16)
        alignment.priority = NSLayoutConstraint.Priority(760)
        alignment.isActive = true
        islandAlignment = alignment
    }

    /// Outside full screen the leading glyphs clear the traffic lights; in it they move to the edge.
    func fullScreen(_ on: Bool) {
        reserve.constant = on ? 12 : Self.trafficLights
    }

    override func layout() {
        // Centers the row on the traffic lights, wherever this macOS draws them.
        if let button = window?.standardWindowButton(.closeButton), let superview = button.superview, !button.isHidden,
            window?.styleMask.contains(.fullScreen) == false
        {
            let midY = convert(button.frame, from: superview).midY
            if midY > 4, midY < Self.height - 4, abs(center.constant - midY) > 0.25 { center.constant = midY }
        } else if center.constant != Self.height / 2 {
            center.constant = Self.height / 2
        }
        super.layout()
    }

    /// The folders down to the file, then the file's name; empty shows only the wordmark.
    func show(path: [String], edited: Bool) {
        dirty.isHidden = !edited || path.isEmpty
        guard path != self.path else { return }
        self.path = path
        rebuildCrumbs()
    }

    /// Who is here: initials in a ring of the writer's color, agents first.
    func show(people writers: [(initials: String, writer: Writer)]) {
        guard writers.map(\.initials) != self.writers.map(\.initials) || writers.map(\.writer) != self.writers.map(\.writer) else { return }
        self.writers = writers
        for view in people.arrangedSubviews { view.removeFromSuperview() }
        for (initials, writer) in writers.prefix(4) {
            people.addArrangedSubview(PresenceDisc(initials, writer: writer))
        }
    }

    private func rebuildCrumbs() {
        for view in crumbs.arrangedSubviews { view.removeFromSuperview() }
        let separator = { () -> NSTextField in
            let slash = NSTextField(labelWithString: "/")
            slash.font = Chrome.mono(12)
            slash.textColor = Chrome.color(.hairline)
            return slash
        }
        if !path.isEmpty { crumbs.addArrangedSubview(separator()) }
        for (index, name) in path.enumerated() {
            let last = index == path.count - 1
            let crumb = Crumb(name, font: last ? Chrome.labelActive : Chrome.mono(12), color: last ? .ink : .ink3) { [weak self] view in
                self?.crumbClicked(index, view)
            }
            crumbs.addArrangedSubview(crumb)
            if !last { crumbs.addArrangedSubview(separator()) }
        }
    }

    @objc private func themeDidChange() {
        wordmark.attributedStringValue = NSAttributedString(string: "dewline", attributes: [
            .font: Chrome.wordmark, .foregroundColor: Chrome.color(.ink), .kern: Chrome.wordmarkKern,
        ])
        dirty.color = Chrome.color(.ink2)
        rebuildCrumbs()
    }
}

/// One step of the title band's path: a folder in mono `ink3`, the file in Bricolage `ink`. A click lists the
/// folder's Markdown files.
private final class Crumb: NSTextField {
    private let clicked: (NSView) -> Void

    init(_ name: String, font: NSFont, color: Token, clicked: @escaping (NSView) -> Void) {
        self.clicked = clicked
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingMiddle
        stringValue = name
        self.font = font
        textColor = Chrome.color(color)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) {
        fatalError("Crumb is built in code")
    }

    override func mouseDown(with event: NSEvent) {
        clicked(self)
    }

    override func accessibilityPerformPress() -> Bool {
        clicked(self)
        return true
    }
}

/// A 20 pt disc with initials in mono, ringed in the writer's color.
private final class PresenceDisc: NSView {
    private let initials: String
    private let writer: Writer

    init(_ initials: String, writer: Writer) {
        self.initials = initials
        self.writer = writer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 22), heightAnchor.constraint(equalToConstant: 22)])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(writer == .collaborator ? initials : writer.name)
        toolTip = writer == .collaborator ? initials : writer.name
    }

    required init?(coder: NSCoder) {
        fatalError("PresenceDisc is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.75, dy: 1.75))
        Chrome.color(.frame).setFill()
        disc.fill()
        ThemeStore.shared.writerColor(writer).setStroke()
        disc.lineWidth = 1.5
        disc.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: Chrome.mono(initials.count > 1 ? 8.5 : 10, weight: .medium), .foregroundColor: Chrome.color(.ink)]
        let size = (initials as NSString).size(withAttributes: attributes)
        (initials as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
