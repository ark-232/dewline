import AppKit

/// The chrome's faces: SF Pro for every label Dewline draws (11 in the status bar, 13 in the sidebar, tabs and panels,
/// 15 semibold for empty-state titles), and JetBrains Mono, which ships in the app's Fonts folder, for code only.
@MainActor
enum Chrome {
    static let monoFamily = "JetBrains Mono"

    /// Section labels' tracking.
    static let sectionKern: CGFloat = 0

    private static var cache: [String: NSFont] = [:]

    /// The system face at `size`, at the nearest of its weights to `weight` on the 100 to 900 scale. `opticalSize` is
    /// kept for callers that name one; SF Pro picks its own.
    static func brand(_ size: CGFloat, weight: CGFloat = 400, opticalSize: CGFloat? = nil) -> NSFont {
        .systemFont(ofSize: size, weight: weight >= 590 ? .semibold : weight >= 500 ? .medium : .regular)
    }

    /// JetBrains Mono at `size`, with the system's monospaced face when it is missing.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = "m \(size) \(weight.rawValue)"
        if let font = cache[key] { return font }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: monoFamily, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        let font = NSFont(descriptor: descriptor, size: size).flatMap { $0.familyName == monoFamily ? $0 : nil }
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
        cache[key] = font
        return font
    }

    /// Sidebar rows, tabs, panels and Settings rows: 13 regular.
    static var label: NSFont { .systemFont(ofSize: 13) }
    /// The selected tab and other emphasis in a row: 13 medium.
    static var labelActive: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    /// The folder's name over its tree: 13 semibold.
    static var labelStrong: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    /// Section labels in the palette and Settings: 11 medium.
    static var section: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    /// Outline headings and secondary rows: 12 regular.
    static var small: NSFont { .systemFont(ofSize: 12) }
    /// The status bar: 11 regular, with tabular digits.
    static var status: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    /// Empty-state titles: 15 semibold.
    static var emptyTitle: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    /// The palette input: 18 regular.
    static var title: NSFont { .systemFont(ofSize: 18) }
    /// Settings pane titles: 15 semibold.
    static var paneTitle: NSFont { .systemFont(ofSize: 15, weight: .semibold) }

    /// Section label text with its tracking.
    static func sectionTitle(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: section, .foregroundColor: color, .kern: sectionKern])
    }

    // MARK: Colors

    static func color(_ token: Token) -> NSColor {
        ThemeStore.shared.color(token)
    }

    /// Ink at 8% in light and 10% in dark: the selected row's fill.
    static var wash: NSColor {
        let ink = color(.ink)
        return NSColor(name: nil) { ink.resolved(for: $0).withAlphaComponent($0.isDark ? 0.10 : 0.08) }
    }

    /// Nothing glows any more; the horizon reads this until it goes.
    static func glowOpacity(dark: Bool) -> Float {
        0
    }

    /// The outer edge of islands and the palette: ink at 8% in light, ink2 at 10% in dark.
    static var strokeSubtle: NSColor {
        let (ink, ink2) = (color(.ink), color(.ink2))
        return NSColor(name: nil) { $0.isDark ? ink2.resolved(for: $0).withAlphaComponent(0.10) : ink.resolved(for: $0).withAlphaComponent(0.08) }
    }
}

/// Dewline's own 1.5 pt line glyphs, in place of SF Symbols, as template images that take their view's tint.
@MainActor
enum Glyph {
    case sidebar, back, forward, up, down, share, close, disclosure, disclosed

    private static var cache: [String: NSImage] = [:]

    var image: NSImage {
        let key = "\(self)"
        if let image = Self.cache[key] { return image }
        let side: CGFloat = switch self {
        case .disclosure, .disclosed, .up, .down: 12
        default: 16
        }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            func line(_ points: [(CGFloat, CGFloat)]) {
                path.move(to: NSPoint(x: points[0].0, y: points[0].1))
                for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
            }
            switch self {
            case .sidebar:
                line([(2.75, 2.75), (2.75, 13.25)])
                line([(6.25, 4.25), (13.25, 4.25)])
                line([(6.25, 8), (11.25, 8)])
                line([(6.25, 11.75), (12.25, 11.75)])
            case .back:
                line([(10, 3.5), (5.5, 8), (10, 12.5)])
            case .forward:
                line([(6, 3.5), (10.5, 8), (6, 12.5)])
            case .up:
                line([(3, 7.5), (6, 4.5), (9, 7.5)])
            case .down:
                line([(3, 4.5), (6, 7.5), (9, 4.5)])
            case .share:
                line([(4.5, 11), (11.5, 4)])
                line([(6.5, 4), (11.5, 4), (11.5, 9)])
                line([(2.75, 13.75), (13.25, 13.75)])
            case .close:
                line([(4.5, 4.5), (11.5, 11.5)])
                line([(11.5, 4.5), (4.5, 11.5)])
            case .disclosure:
                line([(4.5, 2.75), (7.75, 6), (4.5, 9.25)])
            case .disclosed:
                line([(2.75, 4.5), (6, 7.75), (9.25, 4.5)])
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        Self.cache[key] = image
        return image
    }
}

/// A bare glyph button: `ink3` at rest, `ink2` under the pointer, dimmer when disabled. No bezel.
final class GlyphButton: NSButton {
    private var hovering = false {
        didSet { tint() }
    }

    convenience init(_ glyph: Glyph, label: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        image = glyph.image
        imagePosition = .imageOnly
        isBordered = false
        self.target = target
        self.action = action
        toolTip = label
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        tint()
    }

    override var isEnabled: Bool {
        didSet { tint() }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    @objc private func themeDidChange() {
        tint()
    }

    private func tint() {
        contentTintColor = Chrome.color(hovering && isEnabled ? .ink2 : .ink3)
        alphaValue = isEnabled ? 1 : 0.45
    }
}

/// One key as a cap: 20 pt tall, at least 20 wide, 5 pt radius, `keycap` fill with a `hairline` edge one step darker
/// at the bottom, the key in mono 11 `ink2`. On an ink fill the cap takes the island's color at low alpha instead.
@MainActor
enum Keycap {
    static let height: CGFloat = 20
    static let gap: CGFloat = 3

    static func width(_ key: String) -> CGFloat {
        max(height, ceil((key as NSString).size(withAttributes: [.font: Chrome.mono(11)]).width) + 10)
    }

    static func width(_ keys: [String]) -> CGFloat {
        keys.isEmpty ? 0 : keys.map(width).reduce(0, +) + gap * CGFloat(keys.count - 1)
    }

    /// Draws `keys` left to right from `origin`, vertically centered on `midY`, in the current appearance.
    static func draw(_ keys: [String], x origin: CGFloat, midY: CGFloat, onFill: Bool, alpha: CGFloat = 1) {
        var x = origin
        for key in keys {
            let width = width(key)
            let rect = NSRect(x: x, y: midY - height / 2, width: width, height: height)
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            let text: NSColor
            if onFill {
                Chrome.color(.islandEditor).withAlphaComponent(0.16 * alpha).setFill()
                shape.fill()
                text = Chrome.color(.islandEditor).withAlphaComponent(alpha)
            } else {
                Chrome.color(.keycap).withAlphaComponent(alpha).setFill()
                shape.fill()
                Chrome.color(.hairline).withAlphaComponent(alpha).setStroke()
                shape.lineWidth = 1
                shape.stroke()
                // The bottom edge one step darker, so the cap reads as a key.
                let bottom = NSBezierPath()
                let y = NSGraphicsContext.current?.isFlipped == true ? rect.maxY - 0.5 : rect.minY + 0.5
                bottom.move(to: NSPoint(x: rect.minX + 4, y: y))
                bottom.line(to: NSPoint(x: rect.maxX - 4, y: y))
                bottom.lineWidth = 1
                Chrome.color(.ink3).withAlphaComponent(0.35 * alpha).setStroke()
                bottom.stroke()
                text = Chrome.color(.ink2).withAlphaComponent(alpha)
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: Chrome.mono(11), .foregroundColor: text]
            let size = (key as NSString).size(withAttributes: attributes)
            (key as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            x += width + gap
        }
    }
}

/// A chrome button drawn by Dewline: a text button in `ink2` (`ink` under the pointer), or, filled, `ink` with the
/// island's color for its text, 6 pt radius, 28 pt tall. Signal never fills it. Keycaps follow the title.
final class ChromeButton: NSControl {
    enum Style {
        case text, filled
    }

    private let title: String
    private let keys: [String]
    private let style: Style
    private let handler: () -> Void
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(_ title: String, keys: [String] = [], style: Style = .text, label: String? = nil, _ handler: @escaping () -> Void) {
        self.title = title
        self.keys = keys
        self.style = style
        self.handler = handler
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label ?? title)
        toolTip = keys.isEmpty ? nil : "\(title) (\(keys.joined()))"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ChromeButton is built in code")
    }

    override var isFlipped: Bool { true }

    private var titleFont: NSFont { style == .filled ? Chrome.labelActive : Chrome.label }

    override var intrinsicContentSize: NSSize {
        let text = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let caps = keys.isEmpty ? 0 : 8 + Keycap.width(keys)
        return NSSize(width: (style == .filled ? 14 : 6) * 2 + text + caps, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let filled = style == .filled
        if filled {
            Chrome.color(.ink).withAlphaComponent(pressed ? 0.82 : 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let color: NSColor = filled ? Chrome.color(.paper) : Chrome.color(hovering || pressed ? .ink : .ink2)
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        let x: CGFloat = filled ? 14 : 6
        (title as NSString).draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attributes)
        if !keys.isEmpty {
            Keycap.draw(keys, x: x + ceil(size.width) + 8, midY: bounds.midY, onFill: filled, alpha: isEnabled ? 1 : 0.6)
        }
        if window?.firstResponder === self {
            Chrome.color(.accent).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 1.5
            ring.stroke()
        }
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

    override func accessibilityPerformPress() -> Bool {
        handler()
        return true
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}

/// The d-bead mark: a stem and a line in the theme's ink and a round bead in sea, fitted to the view and resting on
/// its bottom edge. Drawn on the icon's 1024 grid, where the mark spans x 160 to 832 and y 288 to 832.
final class DewMark: NSView {
    /// The brand's sea, the bead's color in every theme.
    private static let sea = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0x7F / 255, green: 0xC4 / 255, blue: 0xB2 / 255, alpha: 1)
            : NSColor(srgbRed: 0x2F / 255, green: 0x73 / 255, blue: 0x65 / 255, alpha: 1)
    }

    init(size: NSSize = NSSize(width: 18, height: 12)) {
        super.init(frame: NSRect(origin: .zero, size: size))
        setAccessibilityElement(false)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("DewMark is built in code")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width / 672, bounds.height / 544)
        context.translateBy(x: (bounds.width - 672 * scale) / 2, y: bounds.height - 544 * scale)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -160, y: -288)
        // The whole bead draws first: the line covers its lower part, so no seam shows where it rests.
        Self.sea.resolved(for: effectiveAppearance).setFill()
        NSBezierPath(ovalIn: NSRect(x: 280, y: 428.9, width: 384, height: 384)).fill()
        Chrome.color(.ink).resolved(for: effectiveAppearance).setFill()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 640, y: 312.9))
        stem.line(to: NSPoint(x: 768, y: 288))
        stem.line(to: NSPoint(x: 768, y: 832))
        stem.line(to: NSPoint(x: 640, y: 832))
        stem.close()
        stem.fill()
        NSBezierPath(ovalIn: NSRect(x: 160, y: 768, width: 64, height: 64)).fill()
        NSBezierPath(rect: NSRect(x: 192, y: 768, width: 640, height: 64)).fill()
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}

/// A selected row: an ink wash at 6 pt radius. No hover, no system highlight. Cells that conform to `ChromeSelectable`
/// hear about selection.
final class StationRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for index in 0..<numberOfColumns {
                (view(atColumn: index) as? ChromeSelectable)?.selected = isSelected
            }
        }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 0)
        Chrome.wash.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ChromeSelectable)?.selected = isSelected
    }
}

/// A cell that changes its ink when its row is selected.
@MainActor
protocol ChromeSelectable: AnyObject {
    var selected: Bool { get set }
}

/// A round dot in one color, such as a writer's.
final class Dot: NSView {
    var color: NSColor? {
        didSet { needsDisplay = true }
    }

    convenience init(diameter: CGFloat) {
        self.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
