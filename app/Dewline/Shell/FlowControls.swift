import AppKit

/// The neutral colors the Keep bar, the Changes tab and the conflict card draw with, from the theme's paper and ink.
@MainActor
enum FlowColors {
    /// Panels and bars: paper with 2% ink.
    static var chrome: NSColor {
        let (paper, ink) = (ThemeStore.shared.color(.paper), ThemeStore.shared.color(.ink))
        return NSColor(name: nil) { appearance in
            let paper = paper.resolved(for: appearance)
            return paper.blended(withFraction: 0.02, of: ink.resolved(for: appearance)) ?? paper
        }
    }

    /// Hairlines: ink at 10%.
    static var rule: NSColor {
        let ink = ThemeStore.shared.color(.ink)
        return NSColor(name: nil) { ink.resolved(for: $0).withAlphaComponent($0.isDark ? 0.16 : 0.10) }
    }

    /// A selected or hovered row: ink at 8%.
    static var selection: NSColor {
        let ink = ThemeStore.shared.color(.ink)
        return NSColor(name: nil) { ink.resolved(for: $0).withAlphaComponent(0.08) }
    }
}

/// A text button in SF Pro 13: plain in `ink2` (`ink` under the pointer), quiet in `ink2` without a hover change, or
/// filled with ink and set in paper, 6 pt radius, 24 pt tall.
final class FlowButton: NSControl {
    enum Style {
        case plain, quiet, filled
    }

    var title: String {
        didSet {
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var handler: () -> Void
    private let style: Style
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(_ title: String, style: Style = .plain, _ handler: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.handler = handler
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FlowButton is built in code")
    }

    override var isFlipped: Bool { true }

    private var titleFont: NSFont {
        .systemFont(ofSize: 13, weight: style == .filled ? .medium : .regular)
    }

    override var intrinsicContentSize: NSSize {
        let text = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        return NSSize(width: text + (style == .filled ? 24 : 12), height: 24)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        handler()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let store = ThemeStore.shared
        let filled = style == .filled
        if filled {
            store.color(.ink).withAlphaComponent(pressed ? 0.82 : 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        } else if pressed {
            FlowColors.selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let color = filled ? store.color(.paper) : store.color(style == .plain && (hovering || pressed) ? .ink : .ink2)
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color.withAlphaComponent(isEnabled ? 1 : 0.4)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            store.color(.accent).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { handler() }
                return
            }
            pressed = inside
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { handler() } else { super.keyDown(with: event) }
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}
