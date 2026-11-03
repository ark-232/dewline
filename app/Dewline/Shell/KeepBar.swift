import AppKit
import MdCore

/// Keep and Revert, along the bottom of the editor while the open note has changes waiting: "Claude changed 3
/// places", "· 2 other notes" when other notes wait too, the pager "‹ 2 of 3 ›", then Revert and Keep. Keys show in
/// tooltips only. Keep and Revert act on `focusedChange`, and so do ⌘↩ and ⌥⌘⌫.
final class KeepBar: NSView {
    static let height: CGFloat = 36

    /// The change Keep and Revert act on: the one holding the caret, else the one the pager shows.
    private(set) var focusedChange: UInt64?

    private weak var textView: EditorTextView?
    private weak var live: LiveFile?
    private let summary = NSTextField(labelWithString: "")
    private let others = FlowButton("", style: .quiet) {}
    private let counter = NSTextField(labelWithString: "")
    private let previous = FlowButton("\u{2039}", style: .quiet) {}
    private let next = FlowButton("\u{203A}", style: .quiet) {}
    private var order: [UInt64] = []
    private var observed: [(AnyObject, Notification.Name)] = []
    private var height: NSLayoutConstraint!
    private(set) var shown = false
    /// Every bar, so a text view's Keep and Revert keys find the change its bar shows.
    private static let bars = NSHashTable<KeepBar>.weakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        summary.font = .systemFont(ofSize: 13, weight: .medium)
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        others.handler = { [weak self] in
            guard let self else { return }
            NSApp.sendAction(#selector(ShellActions.toggleChanges(_:)), to: nil, from: self)
        }
        others.toolTip = "Changes (\u{21E7}\u{2318}R)"
        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        previous.handler = { [weak self] in self?.step(-1) }
        previous.toolTip = "Previous Change (\u{2303}\u{2318}\u{2191})"
        previous.setAccessibilityLabel("Previous change")
        next.handler = { [weak self] in self?.step(1) }
        next.toolTip = "Next Change (\u{2303}\u{2318}\u{2193})"
        next.setAccessibilityLabel("Next change")
        let revert = FlowButton("Revert", style: .plain) { [weak self] in self?.decide(keep: false) }
        revert.toolTip = "Revert (\u{2325}\u{2318}\u{232B})"
        let keep = FlowButton("Keep", style: .filled) { [weak self] in self?.decide(keep: true) }
        keep.toolTip = "Keep (\u{2318}\u{21A9})"
        let left = NSStackView(views: [summary, others])
        left.spacing = 4
        left.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let pager = NSStackView(views: [previous, counter, next])
        pager.spacing = 0
        let right = NSStackView(views: [pager, revert, keep])
        right.spacing = 8
        right.setCustomSpacing(16, after: pager)
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            left.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.height / 2),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: left.centerYAnchor),
        ])
        isHidden = true
        Self.bars.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        // Another note's changes change "· 2 other notes".
        NotificationCenter.default.addObserver(self, selector: #selector(changesChanged), name: LiveFile.changesDidChange, object: nil)
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("KeepBar is built in code")
    }

    override var isFlipped: Bool { true }

    /// Follows `textView`'s note and caret; nil hides the bar.
    func attach(to textView: EditorTextView?) {
        for (object, name) in observed { NotificationCenter.default.removeObserver(self, name: name, object: object) }
        observed = []
        self.textView = textView
        live = textView?.marks.live
        focusedChange = nil
        if let textView {
            NotificationCenter.default.addObserver(self, selector: #selector(caretMoved), name: NSTextView.didChangeSelectionNotification, object: textView)
            observed.append((textView, NSTextView.didChangeSelectionNotification))
        }
        changesChanged()
    }

    /// The change the Keep bar showing `live` has focused, for the Keep and Revert keys.
    static func focusedChange(for live: LiveFile?) -> UInt64? {
        guard let live else { return nil }
        return bars.allObjects.first { $0.live === live && $0.shown }?.focusedChange
    }

    private var pending: [UInt64: LiveFile.Change] {
        live?.changes.filter { $0.value.marked && !$0.value.conflict } ?? [:]
    }

    @objc private func changesChanged() {
        let changes = pending
        order = changes.sorted { $0.value.range.location < $1.value.range.location }.map(\.key)
        if focusedChange.map({ changes[$0] == nil }) ?? true { focusedChange = atCaret ?? order.first }
        show(!order.isEmpty)
        refresh()
    }

    @objc private func caretMoved() {
        guard let id = atCaret, id != focusedChange else { return }
        focusedChange = id
        refresh()
    }

    private var atCaret: UInt64? {
        guard let caret = textView?.selectedRange().location else { return nil }
        return order.first { id in
            guard let range = pending[id]?.range else { return false }
            return NSLocationInRange(caret, range) || caret == NSMaxRange(range)
        }
    }

    /// Other notes with undecided changes: the window's other tabs, then notes changed while closed.
    var otherNotes: Int {
        Review.files(in: window).count { $0 !== live && $0.changes.values.contains(where: \.marked) } + Review.closedCount
    }

    private func refresh() {
        guard let focusedChange, let index = order.firstIndex(of: focusedChange) else { return }
        summary.stringValue = Self.summary(pending.values.map(\.origin))
        let count = otherNotes
        others.title = count == 0 ? "" : "\u{00B7} \(count) other \(count == 1 ? "note" : "notes")"
        others.isHidden = count == 0
        counter.stringValue = "\(index + 1) of \(order.count)"
        previous.isEnabled = order.count > 1
        next.isEnabled = order.count > 1
        setAccessibilityLabel("\(summary.stringValue), change \(index + 1) of \(order.count)")
    }

    /// "Claude changed 3 places", "Claude and git changed 4 places", "3 writers changed 6 places".
    static func summary(_ origins: [ChangeEngine.Origin]) -> String {
        var names: [String] = []
        for origin in origins.sorted(by: { MarkWriter($0).name < MarkWriter($1).name }) where !names.contains(MarkWriter(origin).name) {
            names.append(MarkWriter(origin).name)
        }
        let who = names.count <= 2 ? names.joined(separator: " and ") : "\(names.count) writers"
        return "\(who) changed \(origins.count) \(origins.count == 1 ? "place" : "places")"
    }

    private func step(_ delta: Int) {
        guard let focusedChange, let index = order.firstIndex(of: focusedChange), !order.isEmpty else { return }
        let target = order[(index + delta + order.count) % order.count]
        self.focusedChange = target
        refresh()
        live?.reveal(target, caret: true)
    }

    private func decide(keep: Bool) {
        guard let focusedChange else { return }
        if keep { live?.keep(focusedChange) } else { live?.revert(focusedChange) }
    }

    /// Fades in over 160 ms and out over 120 ms; under Reduce Motion it shows and hides at once.
    private func show(_ visible: Bool) {
        guard visible != shown else { return }
        shown = visible
        height.constant = visible ? Self.height : 0
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isHidden = !visible
            return
        }
        isHidden = false
        alphaValue = visible ? 0 : 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.16 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.isHidden = true
                self.alphaValue = 1
            }
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = FlowColors.chrome.resolved(for: effectiveAppearance).cgColor
        let rule = layer?.sublayers?.first { $0.name == "rule" } ?? {
            let rule = CALayer()
            rule.name = "rule"
            layer?.addSublayer(rule)
            return rule
        }()
        rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        rule.backgroundColor = FlowColors.rule.resolved(for: effectiveAppearance).cgColor
    }

    @objc private func themeDidChange() {
        summary.textColor = ThemeStore.shared.color(.ink)
        counter.textColor = ThemeStore.shared.color(.ink2)
        needsDisplay = true
        refresh()
    }
}
