import AppKit
import MdCore

/// The horizon: a 1 px `hairline` across the top of the editor island, the document's minimap turned sideways. A 3 px
/// `signal` segment with its glow maps what is on screen onto the document's height, and an 8 pt bead in the writer's
/// color sits at each pending change, ringed in the island's color. A change on screen always has its bead inside the
/// lit segment, since both map heights the same way. A new bead drops in and pulses once. A click on a bead jumps to
/// its change; a drag on the segment scrolls; a click elsewhere on the line scrolls there.
final class HorizonView: NSView {
    static let height: CGFloat = 18

    /// Where each bead sits, by change, for the Keep/Revert bar's segment.
    private(set) var beadX: [UInt64: CGFloat] = [:]
    /// The beads moved; the bar's segment follows.
    var beadsMoved: () -> Void = {}

    private weak var textView: EditorTextView?
    private weak var live: LiveFile?
    private let line = CALayer()
    private let lit = CALayer()
    private var beads: [UInt64: CALayer] = [:]
    /// Each change's y in the text, measured when the changes or the text's height change, not on every scroll.
    private var heights: [UInt64: CGFloat] = [:]
    private var seen: Set<UInt64> = []
    private var observed: [(AnyObject, Notification.Name)] = []
    private var drag: (startX: CGFloat, startY: CGFloat)?
    private var remeasure: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(line)
        layer?.addSublayer(lit)
        lit.cornerRadius = 1.5
        lit.shadowOffset = .zero
        lit.shadowRadius = 3
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document map")
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("HorizonView is built in code")
    }

    /// Follows `textView`'s scroll and height and `live`'s changes; nil for a page without a file.
    func attach(_ textView: EditorTextView?, live: LiveFile?) {
        for (object, name) in observed { NotificationCenter.default.removeObserver(self, name: name, object: object) }
        observed = []
        self.textView = textView
        self.live = live
        for bead in beads.values { bead.removeFromSuperlayer() }
        beads = [:]
        heights = [:]
        // Changes already waiting when the file opens sit still; only new ones drop in.
        seen = Set(live?.changes.keys.map { $0 } ?? [])
        func observe(_ object: AnyObject?, _ name: Notification.Name, _ selector: Selector) {
            guard let object else { return }
            NotificationCenter.default.addObserver(self, selector: selector, name: name, object: object)
            observed.append((object, name))
        }
        if let textView {
            textView.postsFrameChangedNotifications = true
            observe(textView, NSView.frameDidChangeNotification, #selector(heightChanged))
            observe(textView.enclosingScrollView?.contentView, NSView.boundsDidChangeNotification, #selector(scrolled))
        }
        observe(live, LiveFile.changesDidChange, #selector(changesChanged))
        changesChanged()
    }

    private var pending: [UInt64: LiveFile.Change] {
        live?.changes.filter(\.value.marked) ?? [:]
    }

    @objc private func changesChanged() {
        measure()
        update(arriving: Set(pending.keys).subtracting(seen))
        seen.formUnion(pending.keys)
    }

    @objc private func heightChanged() {
        remeasure?.cancel()
        remeasure = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            measure()
            update(arriving: [])
        }
        scrolled()
    }

    @objc private func scrolled() {
        placeSegment()
    }

    @objc private func themeDidChange() {
        update(arriving: [])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(arriving: [])
    }

    override func layout() {
        super.layout()
        update(arriving: [])
    }

    private func measure() {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        heights = pending.reduce(into: [:]) { heights, entry in
            let location = min(entry.value.range.location, max(length - 1, 0))
            heights[entry.key] = textView.baseline(at: location)
                ?? CGFloat(location) / CGFloat(max(length, 1)) * textView.bounds.height
        }
    }

    private var documentHeight: CGFloat {
        max(textView?.bounds.height ?? 1, 1)
    }

    /// The x on the line for a height in the text.
    private func x(for y: CGFloat) -> CGFloat {
        min(max(y / documentHeight * bounds.width, 0), bounds.width)
    }

    private var segment: (minX: CGFloat, maxX: CGFloat) {
        guard let clip = textView?.enclosingScrollView?.contentView else { return (0, 0) }
        let visible = clip.bounds
        guard documentHeight > visible.height else { return (0, bounds.width) }
        var minX = x(for: visible.minY)
        var maxX = x(for: visible.maxY)
        if maxX - minX < 16 {
            let mid = (minX + maxX) / 2
            minX = max(mid - 8, 0)
            maxX = min(minX + 16, bounds.width)
        }
        return (minX, maxX)
    }

    private func placeSegment() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let (minX, maxX) = segment
        lit.isHidden = textView == nil
        lit.frame = NSRect(x: minX, y: bounds.midY - 1.5, width: maxX - minX, height: 3)
        CATransaction.commit()
    }

    private func update(arriving: Set<UInt64>) {
        let appearance = effectiveAppearance
        let dark = appearance.isDark
        let scale = window?.backingScaleFactor ?? 2
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = NSRect(x: 0, y: bounds.midY - 0.5 / scale, width: bounds.width, height: 1 / scale)
        line.backgroundColor = Chrome.color(contrast ? .ink3 : .hairline).resolved(for: appearance).cgColor
        lit.backgroundColor = Chrome.color(.signal).resolved(for: appearance).cgColor
        lit.shadowColor = Chrome.color(.glow).resolved(for: appearance).cgColor
        lit.shadowOpacity = Chrome.glowOpacity(dark: dark)
        CATransaction.commit()
        placeSegment()

        let changes = pending
        for (id, bead) in beads where changes[id] == nil {
            fadeOut(bead)
            beads[id] = nil
        }
        var positions: [UInt64: CGFloat] = [:]
        for (id, change) in changes {
            guard let y = heights[id] else { continue }
            let center = min(max(x(for: y), 4), bounds.width - 4)
            positions[id] = center
            let bead = beads[id] ?? {
                let bead = CALayer()
                bead.cornerRadius = 4
                layer?.addSublayer(bead)
                beads[id] = bead
                return bead
            }()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bead.frame = NSRect(x: center - 4, y: bounds.midY - 4, width: 8, height: 8)
            bead.backgroundColor = MarkWriter(change.origin).color.resolved(for: appearance).cgColor
            bead.borderColor = Chrome.color(.islandEditor).resolved(for: appearance).cgColor
            bead.borderWidth = 1.5
            CATransaction.commit()
            if arriving.contains(id) { arrive(bead, color: bead.backgroundColor) }
        }
        if positions != beadX {
            beadX = positions
            beadsMoved()
        }
        setAccessibilityValue(changes.isEmpty ? "No pending changes" : "\(changes.count) pending \(changes.count == 1 ? "change" : "changes")")
    }

    /// The bead drops 6 pt onto the line and fades in, then a 5 pt halo in the writer's color pulses out once. Under
    /// Reduce Motion the bead only fades in and the halo shows still, then goes.
    private func arrive(_ bead: CALayer, color: CGColor?) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let curve = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduce ? 0.12 : 0.18
        fade.timingFunction = curve
        bead.add(fade, forKey: "arrive")
        if !reduce {
            let drop = CABasicAnimation(keyPath: "position.y")
            drop.fromValue = bead.position.y + 6
            drop.toValue = bead.position.y
            drop.duration = 0.18
            drop.timingFunction = curve
            bead.add(drop, forKey: "drop")
        }
        let halo = CALayer()
        halo.frame = bead.frame.insetBy(dx: -5, dy: -5)
        halo.cornerRadius = halo.frame.width / 2
        halo.backgroundColor = color
        halo.opacity = reduce ? 0.3 : 0
        layer?.insertSublayer(halo, below: bead)
        if reduce {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { halo.removeFromSuperlayer() }
            return
        }
        let pulse = CAAnimationGroup()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 8.0 / 18.0
        grow.toValue = 1
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 0.45
        out.toValue = 0
        pulse.animations = [grow, out]
        pulse.beginTime = CACurrentMediaTime() + 0.18
        pulse.duration = 0.6
        pulse.fillMode = .backwards
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { halo.removeFromSuperlayer() }
        halo.add(pulse, forKey: "pulse")
        CATransaction.commit()
    }

    /// A kept or reverted change's bead fades from the line in 200 ms.
    private func fadeOut(_ bead: CALayer) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { bead.removeFromSuperlayer() }
        bead.opacity = 0
        CATransaction.commit()
    }

    // MARK: Clicks

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let nearest = beadX.min(by: { abs($0.value - point.x) < abs($1.value - point.x) }), abs(nearest.value - point.x) <= 6 {
            live?.reveal(nearest.key, caret: true)
            return
        }
        guard let clip = textView?.enclosingScrollView?.contentView else { return }
        let (minX, maxX) = segment
        if point.x < minX - 2 || point.x > maxX + 2 {
            // Centers the page on the clicked point of the document.
            let target = point.x / max(bounds.width, 1) * documentHeight - clip.bounds.height / 2
            scroll(clip, to: target)
        }
        drag = (point.x, clip.bounds.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let clip = textView?.enclosingScrollView?.contentView else { return }
        let point = convert(event.locationInWindow, from: nil)
        scroll(clip, to: drag.startY + (point.x - drag.startX) / max(bounds.width, 1) * documentHeight)
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    private func scroll(_ clip: NSClipView, to y: CGFloat) {
        let top = min(max(y, 0), max(documentHeight - clip.bounds.height, 0))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        textView?.enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

/// Keep and Revert, docked along the bottom of the editor island while the open file has changes waiting: the
/// writer's dot and name, "changed 2 places in plan.md", the change's place among them with previous and next, then
/// Revert and Keep with their keys. Keep is filled with ink, never signal. A 3 pt segment in the writer's color on
/// the bar's top edge sits under the focused change's bead on the horizon.
final class KeepBar: NSView {
    static let height: CGFloat = 44

    /// The bead's x on the horizon for a change, which the bar's segment matches.
    var beadX: (UInt64) -> CGFloat? = { _ in nil }

    private weak var textView: EditorTextView?
    private weak var live: LiveFile?
    private let dot = Dot(diameter: 6)
    private let name = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let previous = GlyphButton(.up, label: "Previous change", target: nil, action: nil)
    private let next = GlyphButton(.down, label: "Next change", target: nil, action: nil)
    private let rule = NSView()
    private let segment = CALayer()
    private let topRule = CALayer()
    private var focused: UInt64?
    private var order: [UInt64] = []
    private var observed: [(AnyObject, Notification.Name)] = []
    private var height: NSLayoutConstraint!
    private(set) var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(topRule)
        layer?.addSublayer(segment)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        name.font = Chrome.labelStrong
        summary.font = Chrome.label
        summary.lineBreakMode = .byTruncatingMiddle
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counter.font = Chrome.mono(12)
        previous.target = self
        previous.action = #selector(goPrevious)
        next.target = self
        next.action = #selector(goNext)
        rule.wantsLayer = true
        let revert = ChromeButton("Revert", keys: ["⌥", "⌘", "⌫"], label: "Revert this change") { [weak self] in self?.decide(keep: false) }
        let keep = ChromeButton("Keep", keys: ["⌘", "↩"], style: .filled, label: "Keep this change") { [weak self] in self?.decide(keep: true) }
        let left = NSStackView(views: [dot, name, summary])
        left.spacing = 8
        left.setCustomSpacing(6, after: name)
        left.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let pager = NSStackView(views: [previous, counter, next])
        pager.spacing = 2
        let right = NSStackView(views: [pager, rule, revert, keep])
        right.spacing = 12
        right.setCustomSpacing(6, after: revert)
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        rule.translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            rule.widthAnchor.constraint(equalToConstant: 1),
            rule.heightAnchor.constraint(equalToConstant: 16),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            left.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.height / 2 + 0.5),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: left.centerYAnchor),
        ])
        isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("KeepBar is built in code")
    }

    override var isFlipped: Bool { true }

    func attach(_ textView: EditorTextView?, live: LiveFile?) {
        for (object, name) in observed { NotificationCenter.default.removeObserver(self, name: name, object: object) }
        observed = []
        self.textView = textView
        self.live = live
        focused = nil
        if let live {
            NotificationCenter.default.addObserver(self, selector: #selector(changesChanged), name: LiveFile.changesDidChange, object: live)
            observed.append((live, LiveFile.changesDidChange))
        }
        if let textView {
            NotificationCenter.default.addObserver(self, selector: #selector(caretMoved), name: NSTextView.didChangeSelectionNotification, object: textView)
            observed.append((textView, NSTextView.didChangeSelectionNotification))
        }
        changesChanged()
    }

    private var pending: [UInt64: LiveFile.Change] {
        live?.changes.filter { $0.value.marked && !$0.value.conflict } ?? [:]
    }

    @objc private func changesChanged() {
        let changes = pending
        order = changes.sorted { $0.value.range.location < $1.value.range.location }.map(\.key)
        if focused.map({ changes[$0] == nil }) ?? true { focused = atCaret ?? order.first }
        show(!order.isEmpty)
        refresh()
    }

    /// The change holding the caret becomes the focused one.
    @objc private func caretMoved() {
        guard let id = atCaret, id != focused else { return }
        focused = id
        refresh()
    }

    private var atCaret: UInt64? {
        guard let caret = textView?.selectedRange().location else { return nil }
        return order.first { id in
            guard let range = pending[id]?.range else { return false }
            return NSLocationInRange(caret, range) || caret == NSMaxRange(range)
        }
    }

    private func refresh() {
        guard let focused, let change = pending[focused], let index = order.firstIndex(of: focused) else { return }
        let writer = MarkWriter(change.origin)
        let writers = Set(pending.values.map { MarkWriter($0.origin).name })
        let places = order.count
        let file = live?.url.lastPathComponent ?? "this file"
        dot.color = writer.color
        name.stringValue = writer.name
        name.textColor = writer.color
        summary.stringValue = (writers.count > 1 ? "and \(writers.count - 1) more changed " : "changed ")
            + "\(places) \(places == 1 ? "place" : "places") in \(file)"
        counter.stringValue = "\(index + 1) / \(places)"
        previous.isEnabled = places > 1
        next.isEnabled = places > 1
        setAccessibilityLabel("\(writer.name) \(summary.stringValue), change \(index + 1) of \(places)")
        placeSegment()
    }

    /// The bar's segment under the focused change's bead.
    func placeSegment() {
        let appearance = effectiveAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        topRule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale)
        topRule.backgroundColor = Chrome.color(.hairline).resolved(for: appearance).cgColor
        if let focused, let change = pending[focused], let x = beadX(focused) {
            segment.isHidden = false
            segment.frame = NSRect(x: min(max(x - 16, 0), max(bounds.width - 32, 0)), y: 0, width: 32, height: 3)
            segment.backgroundColor = MarkWriter(change.origin).color.resolved(for: appearance).cgColor
        } else {
            segment.isHidden = true
        }
        CATransaction.commit()
    }

    @objc private func goPrevious() {
        step(-1)
    }

    @objc private func goNext() {
        step(1)
    }

    private func step(_ delta: Int) {
        guard let focused, let index = order.firstIndex(of: focused), !order.isEmpty else { return }
        let target = order[(index + delta + order.count) % order.count]
        self.focused = target
        refresh()
        live?.reveal(target, caret: true)
    }

    private func decide(keep: Bool) {
        guard let focused else { return }
        if keep { live?.keep(focused) } else { live?.revert(focused) }
    }

    /// Rises 8 pt with a fade in 160 ms, and falls in 120 ms; under Reduce Motion it only fades.
    private func show(_ visible: Bool) {
        guard visible != shown else { return }
        shown = visible
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard window?.isVisible == true, let layer else {
            height.constant = visible ? Self.height : 0
            isHidden = !visible
            return
        }
        // The page gives up its room at once on the way in and takes it back once the bar has faded.
        if visible { height.constant = Self.height }
        isHidden = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = visible ? 0 : 1
        fade.toValue = visible ? 1 : 0
        let curve = visible ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) : CAMediaTimingFunction(name: .easeIn)
        let duration = visible ? 0.16 : 0.12
        var animations: [CAAnimation] = [fade]
        if !reduce {
            let rise = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
            rise.fromValue = visible ? 8 : 0
            rise.toValue = visible ? 0 : 8
            animations.append(rise)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = curve
        group.fillMode = .forwards
        group.isRemovedOnCompletion = visible
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.shown else { return }
            self.isHidden = true
            self.height.constant = 0
        }
        layer.add(group, forKey: "show")
        CATransaction.commit()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.color(.sunken).resolved(for: effectiveAppearance).cgColor
        rule.layer?.backgroundColor = Chrome.color(.hairline).resolved(for: effectiveAppearance).cgColor
        placeSegment()
    }

    override func layout() {
        super.layout()
        placeSegment()
    }

    @objc private func themeDidChange() {
        summary.textColor = Chrome.color(.ink2)
        counter.textColor = Chrome.color(.ink2)
        needsDisplay = true
        refresh()
    }
}
