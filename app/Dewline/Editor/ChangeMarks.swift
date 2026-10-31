import AppKit
import MdCore

/// A writer's four channels (D21): hue, underline style, small-caps stamp and spoken label.
struct MarkWriter: Equatable {
    let name: String
    let light: OKLCH
    let dark: OKLCH
    /// Unknown app's underline is dashed, so the mark holds without its color.
    let dashed: Bool

    init(_ origin: ChangeEngine.Origin) {
        (name, light, dark, dashed) = switch origin {
        case .agent(.claude, _): ("Claude", OKLCH(l: 0.60, c: 0.15, h: 45), OKLCH(l: 0.72, c: 0.14, h: 45), false)
        case .agent(.codex, _): ("Codex", OKLCH(l: 0.50, c: 0.16, h: 295), OKLCH(l: 0.70, c: 0.14, h: 295), false)
        case .agent(.cursor, _): ("Cursor", OKLCH(l: 0.55, c: 0.13, h: 150), OKLCH(l: 0.74, c: 0.13, h: 150), false)
        case .collaborator(_, let name): (name, OKLCH(l: 0.56, c: 0.20, h: 350), OKLCH(l: 0.72, c: 0.17, h: 350), false)
        case .git: ("git", OKLCH(l: 0.46, c: 0.10, h: 105), OKLCH(l: 0.70, c: 0.11, h: 105), false)
        case .external: ("Unknown app", OKLCH(l: 0.55, c: 0, h: 0), OKLCH(l: 0.70, c: 0, h: 0), true)
        case .user: ("You", OKLCH(l: 0.55, c: 0, h: 0), OKLCH(l: 0.70, c: 0, h: 0), false)
        }
    }

    var color: NSColor {
        let (light, dark) = (light.color, dark.color)
        return NSColor(name: nil) { $0.isDark ? dark : light }
    }

    /// "Claude's"; "the other" for Unknown app.
    var possessive: String {
        dashed ? "the other" : "\(name)'s"
    }

    /// The name as a small-caps stamp in the writer's color: CLAUDE, GIT.
    var stamp: NSAttributedString {
        let base = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector],
            [.typeIdentifier: kUpperCaseType, .selectorIdentifier: kUpperCaseSmallCapsSelector],
        ]
        let font = NSFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: features]), size: 11) ?? base
        return NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: color, .kern: 0.4])
    }

    /// "Claude changed 2 places".
    func spoken(places: Int) -> String {
        "\(name) changed \(places) \(places == 1 ? "place" : "places")"
    }
}

/// Paints marked changes over the text at render time, never as text edits: a wash in the writer's hue under
/// inserted text with an underline in the writer's style, a 3 pt tick in the left gutter and the writer's name on
/// hover. Removed text hangs under its line as a struck ghost and a conflict's other version as a card, each in space
/// the styler reserves below the paragraph. The marks sit under the text; ghosts, cards and the bar sit over it.
@MainActor
final class ChangeMarks: NSView, NSViewToolTipOwner {
    weak var textView: EditorTextView?
    /// Keep, Revert and the card's choices go through the engine here.
    weak var live: LiveFile?
    private var changes: [UInt64: LiveFile.Change] = [:]
    /// The ranges each marked change painted at the last layout, by change.
    private(set) var painted: [UInt64: NSRange] = [:]
    /// When each marked change's fade began.
    private var shown: [UInt64: CFTimeInterval] = [:]
    /// Ghosts and cards by change, with the offset of the character whose paragraph they hang under.
    private(set) var hangers: [UInt64: (anchor: Int, view: NSView)] = [:]
    private var tips: [(rect: NSRect, change: UInt64)] = []
    private var dirty = false
    private var observing: NSView?
    let bar = ChangeBar()

    static let fade: CFTimeInterval = 0.2
    private static let gap: CGFloat = 6

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.actions = ["sublayers": NSNull()]
        return layer
    }

    /// The change engine's pending changes, as the buffer has them now.
    func update(_ changes: [UInt64: LiveFile.Change]) {
        let marked = changes.filter(\.value.marked)
        guard !(marked.isEmpty && self.changes.isEmpty) else { return }
        let now = CACurrentMediaTime()
        shown = shown.filter { marked[$0.key] != nil }
        for id in marked.keys where shown[id] == nil { shown[id] = now }
        self.changes = marked
        updateHangers()
        dirty = true
        textView?.needsLayout = true
    }

    // MARK: Hangers

    private func updateHangers() {
        guard let textView else { return }
        let length = textView.textStorage!.length
        var wanted: [UInt64: Int] = [:]
        for (id, change) in changes where change.conflict || !change.removed.isEmpty {
            let end = change.range.length > 0 ? NSMaxRange(change.range) - 1 : change.range.location - 1
            wanted[id] = min(max(end, 0), max(length - 1, 0))
        }
        var touched: [Int] = []
        for (id, hanger) in hangers where wanted[id] == nil {
            hanger.view.removeFromSuperview()
            hangers[id] = nil
            touched.append(hanger.anchor)
        }
        for (id, anchor) in wanted {
            if let hanger = hangers[id] {
                if hanger.anchor != anchor { hangers[id] = (anchor, hanger.view) }
                continue
            }
            let change = changes[id]!
            let view: NSView = change.conflict
                ? ConflictCard(MarkWriter(change.origin), theirs: change.theirs) { [weak self] decision in
                    self?.live?.decide(id, decision)
                }
                : Ghost(change.removed, writer: MarkWriter(change.origin))
            textView.addSubview(view)
            hangers[id] = (anchor, view)
            touched.append(anchor)
        }
        guard !touched.isEmpty else { return }
        measureHangers()
        reserve(touched)
    }

    /// Has the styler reserve space under the paragraphs holding `anchors` on the run loop's next pass, outside the
    /// storage edit or layout that asked, then lays the marks out again.
    private func reserve(_ anchors: [Int]) {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView else { return }
                let text = textView.textStorage!.mutableString
                for anchor in anchors where anchor < text.length {
                    textView.styler.restyleNow(text.paragraphRange(for: NSRange(location: anchor, length: 0)))
                }
                self.dirty = true
                textView.needsLayout = true
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private var columnWidth: CGFloat {
        guard let textView, let container = textView.textContainer else { return 0 }
        return container.size.width - 2 * container.lineFragmentPadding
    }

    private func measureHangers() {
        let width = columnWidth
        for hanger in hangers.values where hanger.view.frame.width != width {
            hanger.view.setFrameSize(NSSize(width: width, height: (hanger.view as? Hanging)?.height(for: width) ?? 0))
        }
    }

    /// Space to reserve under the paragraphs holding these offsets, for the styler.
    func space(in range: NSRange) -> [(anchor: Int, height: CGFloat)] {
        hangers.values.filter { NSLocationInRange($0.anchor, range) }.map { ($0.anchor, $0.view.frame.height + 2 * Self.gap) }
    }

    // MARK: Layout

    /// Lays the marks out again after the text's layout when something changed.
    func layoutIfDirty() {
        guard dirty else { return }
        relayout()
    }

    func relayout() {
        dirty = false
        guard let textView, let layer else { return }
        if frame != textView.bounds { frame = textView.bounds }
        let heights = hangers.mapValues(\.view.frame.height)
        measureHangers()
        let resized = hangers.filter { heights[$0.key] != $0.value.view.frame.height }.map(\.value.anchor)
        if !resized.isEmpty { reserve(resized) }
        removeAllToolTips()
        tips = []
        painted = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers = nil
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let dark = effectiveAppearance.isDark
        let wash = contrast ? (dark ? 0.30 : 0.22) : (dark ? 0.24 : 0.15)
        let rule: CGFloat = contrast ? 3 : 2
        let tickWidth: CGFloat = contrast ? 4 : 3
        let left = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        let now = CACurrentMediaTime()
        let motion = Motion.current != .off
        let storage = textView.textStorage!
        var hung: [UInt64: CGFloat] = [:]
        // Hangers under one paragraph stack in change order.
        for (id, hanger) in hangers.sorted(by: { $0.key < $1.key }) {
            guard let top = textBottom(at: hanger.anchor) else { continue }
            let stacked = hangers.filter { $0.key < id && $0.value.anchor == hanger.anchor }.map { $0.value.view.frame.height + Self.gap }
            let y = top + Self.gap + stacked.reduce(0, +)
            hanger.view.frame.origin = NSPoint(x: left, y: y)
            hung[id] = y + hanger.view.frame.height
        }
        for (id, change) in changes where NSMaxRange(change.range) <= storage.length {
            let writer = MarkWriter(change.origin)
            let color = writer.color.resolved(for: effectiveAppearance)
            let group = CALayer()
            let lines = segments(change.range)
            var span = lines.reduce(NSRect.null) { $0.union($1.frame) }
            if lines.isEmpty, let line = lineRect(at: change.range.location) { span = line }
            if let bottom = hung[id], !span.isNull { span.size.height = bottom - span.minY }
            guard !span.isNull else { continue }
            if !change.conflict {
                painted[id] = change.range
                for line in lines where line.frame.width >= 0.5 {
                    let fill = CALayer()
                    fill.frame = line.frame
                    fill.backgroundColor = color.withAlphaComponent(wash).cgColor
                    group.addSublayer(fill)
                    let underline = CAShapeLayer()
                    let y = line.frame.minY + line.baseline + rule + 1
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: line.frame.minX, y: y))
                    path.addLine(to: CGPoint(x: line.frame.maxX, y: y))
                    underline.path = path
                    underline.strokeColor = color.cgColor
                    underline.lineWidth = rule
                    if writer.dashed { underline.lineDashPattern = [4, 3] }
                    group.addSublayer(underline)
                    tips.append((line.frame, id))
                }
            }
            let tick = CALayer()
            tick.frame = NSRect(x: max(left - 36, 4), y: span.minY + 2, width: tickWidth, height: max(span.height - 4, 4))
            tick.cornerRadius = tickWidth / 2
            tick.backgroundColor = color.cgColor
            group.addSublayer(tick)
            tips.append((tick.frame.insetBy(dx: -6, dy: 0), id))
            if motion, let start = shown[id], now - start < Self.fade {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = Self.fade
                fade.beginTime = start
                fade.fillMode = .backwards
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.add(fade, forKey: "fade")
            }
            layer.addSublayer(group)
        }
        CATransaction.commit()
        for tip in tips { addToolTip(tip.rect, owner: self, userData: nil) }
        placeBar()
    }

    private struct Segment {
        let frame: NSRect
        let baseline: CGFloat
    }

    /// The range's line segments in this view's coordinates.
    private func segments(_ range: NSRange) -> [Segment] {
        guard range.length > 0, let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        layout.ensureLayout(for: textRange)
        let origin = textView.textContainerOrigin
        var segments: [Segment] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, baseline, _ in
            segments.append(Segment(frame: frame.offsetBy(dx: origin.x, dy: origin.y), baseline: baseline))
            return true
        }
        return segments
    }

    private func fragment(at index: Int) -> NSTextLayoutFragment? {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: index)
        else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        return layout.textLayoutFragment(for: location)
    }

    /// The bottom of the text of the paragraph holding `index`, above any space reserved under it.
    private func textBottom(at index: Int) -> CGFloat? {
        guard let textView, let fragment = fragment(at: index) else { return nil }
        let bottom = fragment.textLineFragments.last?.typographicBounds.maxY ?? fragment.layoutFragmentFrame.height
        return textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + bottom
    }

    private func lineRect(at index: Int) -> NSRect? {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return nil }
        let index = min(max(index, 0), storage.length - 1)
        guard let fragment = fragment(at: index), let content = textView.textLayoutManager?.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: index)
        else { return nil }
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        let line = fragment.textLineFragments.first { NSLocationInRange(offset, $0.characterRange) } ?? fragment.textLineFragments.last
        guard let line else { return nil }
        let frame = fragment.layoutFragmentFrame
        return line.typographicBounds.offsetBy(dx: frame.minX + textView.textContainerOrigin.x, dy: frame.minY + textView.textContainerOrigin.y)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let tip = tips.first(where: { $0.rect.contains(point) }), let change = changes[tip.change] else { return "" }
        return change.conflict ? "\(MarkWriter(change.origin).name) · two versions" : MarkWriter(change.origin).name
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !changes.isEmpty { relayout() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let clip = enclosingScrollView?.contentView
        guard clip !== observing else { return }
        if let observing { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observing) }
        observing = clip
        if let clip {
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    /// TextKit 2 replaces its estimates as it lays out the text it scrolls to, so marks off screen move with them.
    @objc private func scrolled() {
        if !changes.isEmpty { relayout() }
    }

    // MARK: The change under the caret

    /// The marked change holding the caret, a conflict first.
    var changeAtCaret: UInt64? {
        guard let caret = textView?.selectedRanges.first?.rangeValue.location else { return nil }
        let holding = changes.filter { NSLocationInRange(caret, $0.value.range) || caret == NSMaxRange($0.value.range) }
        return holding.first { $0.value.conflict }?.key ?? holding.keys.min()
    }

    /// The bar follows the caret at the next layout.
    func caretMoved() {
        guard !changes.isEmpty || bar.superview != nil else { return }
        dirty = true
        textView?.needsLayout = true
    }

    private func placeBar() {
        guard let textView, let id = changeAtCaret, let change = changes[id], !change.conflict else {
            bar.removeFromSuperview()
            return
        }
        let lines = segments(change.range)
        guard let last = lines.last?.frame ?? lineRect(at: change.range.location) else { return }
        var bottom = last.maxY
        if let hanger = hangers[id]?.view { bottom = max(bottom, hanger.frame.maxY) }
        bar.show(MarkWriter(change.origin)) { [weak self] keep in
            if keep { self?.live?.keep(id) } else { self?.live?.revert(id) }
        }
        let left = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        bar.frame = NSRect(origin: NSPoint(x: left, y: bottom + 8), size: bar.fittingSize)
        if bar.superview !== textView { textView.addSubview(bar) }
    }

    /// Cmd-Return: keeps the change under the caret, or both versions of a conflict.
    func keepAtCaret() {
        guard let id = changeAtCaret else { return }
        live?.keep(id)
    }

    /// Option-Cmd-Delete: reverts the change under the caret, or keeps your version of a conflict.
    func revertAtCaret() {
        guard let id = changeAtCaret else { return }
        live?.revert(id)
    }

    /// One announcement per marked landing.
    func announce(_ origin: ChangeEngine.Origin, places: Int) {
        guard let textView, places > 0 else { return }
        NSAccessibility.post(element: textView, notification: .announcementRequested, userInfo: [
            .announcement: MarkWriter(origin).spoken(places: places),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

extension NSColor {
    /// The color as `appearance` draws it.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: self.cgColor) ?? self }
        return resolved
    }
}
