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

/// What MainWindowController still calls while it lays out the horizon. Horizon.swift goes once it doesn't.
extension KeepBar {
    func attach(_ textView: EditorTextView?, live: LiveFile?) {
        attach(to: textView)
    }

    var beadX: (UInt64) -> CGFloat? {
        get { { _ in nil } }
        set {}
    }

    func placeSegment() {}
}

/// MainWindowController's slot for the finished line, which the Keep bar replaced; it never shows.
final class FinishedLine: NSView {
    static let height: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("FinishedLine is built in code")
    }

    func show(_ origin: ChangeEngine.Origin) {}

    func dismiss() {}
}
