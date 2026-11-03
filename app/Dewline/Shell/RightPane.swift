import AppKit

/// The pane on the window's right, 380 pt by default: one of Preview, Agent and Changes under a segmented header.
/// Agent and Changes show once their parts of the app register what they draw.
final class RightPane: NSViewController {
    enum Tab: Int, CaseIterable {
        case preview, agent, changes

        var title: String {
            switch self {
            case .preview: "Preview"
            case .agent: "Agent"
            case .changes: "Changes"
            }
        }
    }

    static let width: CGFloat = 380
    static let widths: ClosedRange<CGFloat> = 300...560

    /// The agent panel for a window; nil leaves the Agent segment out.
    static var makeAgent: (@MainActor (NSWindow) -> NSViewController)?
    /// The Changes list for a window; nil leaves the Changes segment out.
    static var makeChanges: (@MainActor (NSWindow) -> NSViewController)?

    /// Shows `tab` in `window`'s pane, or the main window's, opening the pane.
    static func show(_ tab: Tab, in window: NSWindow? = nil) {
        ((window ?? NSApp.mainWindow)?.windowController as? MainWindowController)?.showPane(tab)
    }

    let preview = PreviewPane()
    private(set) var tab: Tab = .preview
    /// The segment the user picked, to keep across this window's tabs.
    var picked: (Tab) -> Void = { _ in }
    /// The changes waiting for a decision, shown on the Changes segment when there are any.
    var changesCount = 0 {
        didSet { if changesCount != oldValue { labelSegments() } }
    }

    private let segments = NSSegmentedControl()
    private let content = NSView()
    private var built: [Tab: NSViewController] = [:]

    private var tabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .preview: true
            case .agent: Self.makeAgent != nil
            case .changes: Self.makeChanges != nil
            }
        }
    }

    override func loadView() {
        let root = ChromeFill()
        segments.segmentStyle = .automatic
        segments.trackingMode = .selectOne
        segments.controlSize = .regular
        segments.target = self
        segments.action = #selector(segmentPicked)
        segments.setAccessibilityLabel("Pane")
        let rule = RuleLine()
        for view in [segments, rule, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            segments.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            segments.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            segments.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
            rule.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: rule.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        labelSegments()
        select(tab)
    }

    private func labelSegments() {
        let tabs = tabs
        segments.segmentCount = tabs.count
        for (index, tab) in tabs.enumerated() {
            let count = tab == .changes && changesCount > 0 ? " \(changesCount)" : ""
            segments.setLabel(tab.title + count, forSegment: index)
            segments.setWidth(0, forSegment: index)
        }
        segments.selectedSegment = tabs.firstIndex(of: tab) ?? 0
    }

    @objc private func segmentPicked() {
        let tabs = tabs
        guard tabs.indices.contains(segments.selectedSegment) else { return }
        select(tabs[segments.selectedSegment])
        picked(tab)
    }

    /// Puts `tab`'s content in the pane; a tab this build has no content for falls back to Preview.
    func select(_ tab: Tab) {
        let tab = tabs.contains(tab) ? tab : .preview
        self.tab = tab
        guard isViewLoaded else { return }
        labelSegments()
        for child in content.subviews { child.removeFromSuperview() }
        guard let controller = controller(for: tab) else { return }
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: content.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func controller(for tab: Tab) -> NSViewController? {
        if let built = built[tab] { return built }
        let made: NSViewController? = switch tab {
        case .preview: preview
        case .agent: view.window.flatMap { window in Self.makeAgent?(window) }
        case .changes: view.window.flatMap { window in Self.makeChanges?(window) }
        }
        if let made {
            addChild(made)
            built[tab] = made
        }
        return made
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Agent and Changes need the window to build.
        if built[tab] == nil { select(tab) }
    }
}

/// A view filled with the theme's chrome, following the theme and the appearance.
final class ChromeFill: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ChromeFill is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.color(.chrome).resolved(for: effectiveAppearance).cgColor
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}
