import AppKit
import MdCore

/// A view that hangs under a paragraph in space the styler reserves for it.
@MainActor
protocol Hanging: NSView {
    func height(for width: CGFloat) -> CGFloat
}

/// The opaque fill of Dewline's floating controls: paper mixed 92% with the sidebar tint, a 0.5 pt edge at ink 12%.
@MainActor
private func paint(_ layer: CALayer?, in view: NSView, radius: CGFloat) {
    guard let layer else { return }
    let store = ThemeStore.shared
    let appearance = view.effectiveAppearance
    let paper = store.color(.paper).resolved(for: appearance)
    let tint = store.color(.sidebarTint).resolved(for: appearance)
    layer.backgroundColor = (paper.blended(withFraction: 0.08, of: tint) ?? paper).cgColor
    layer.borderColor = store.color(.ink).resolved(for: appearance).withAlphaComponent(0.12).cgColor
    layer.borderWidth = 0.5
    layer.cornerRadius = radius
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = appearance.isDark ? 0.35 : 0.10
    layer.shadowRadius = 6
    layer.shadowOffset = CGSize(width: 0, height: -2)
}

@MainActor
private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: Token) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Chrome.brand(size, weight: weight == .semibold ? 600 : 450)
    label.textColor = ThemeStore.shared.color(color)
    return label
}

/// A button that calls `action` when clicked, drawn as Station's chrome: the prominent one filled with ink and set in
/// the island's color, the others bare text in `ink2`. Signal never fills it.
@MainActor
private final class ActionButton: NSButton {
    private var handler: () -> Void = {}
    private var prominent = false

    convenience init(_ title: String, prominent: Bool = false, shortcut: String? = nil, label: String, _ action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.prominent = prominent
        handler = action
        target = self
        self.action = #selector(clicked)
        isBordered = false
        wantsLayer = true
        toolTip = shortcut.map { "\(title) (\($0))" }
        setAccessibilityLabel(label)
        paint()
        NotificationCenter.default.addObserver(self, selector: #selector(paint), name: ThemeStore.didChange, object: nil)
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + (prominent ? 24 : 8), height: 24)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = prominent ? ThemeStore.shared.color(.ink).resolved(for: effectiveAppearance).cgColor : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    @objc private func paint() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: prominent ? Chrome.labelActive : Chrome.label,
            .foregroundColor: ThemeStore.shared.color(prominent ? .islandEditor : .ink2),
        ])
        needsDisplay = true
    }

    @objc private func clicked() {
        handler()
    }
}

/// Removed text, struck, at ink 42% with the strike in the writer's color. A short removal on one line reads inline
/// at its deletion point, in a gap the styler opens there; a longer one hangs under its paragraph.
@MainActor
final class Ghost: NSView, Hanging {
    private let string: NSAttributedString
    private let text: NSTextField?
    /// The gap an inline ghost takes in its line, its text and a space; nil for a ghost that hangs.
    let inlineWidth: CGFloat?
    /// From an inline ghost's top to its baseline.
    let ascent: CGFloat

    /// A ghost no wider than `limit` reads inline.
    init(_ removed: String, writer: MarkWriter, inlineUpTo limit: CGFloat) {
        let shown = removed.hasSuffix("\n") ? String(removed.dropLast()) : removed
        let font = ThemeStore.shared.bodyFont
        string = NSAttributedString(string: shown, attributes: [
            .font: font,
            .foregroundColor: ThemeStore.shared.color(.ink).withAlphaComponent(0.42),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: writer.color,
        ])
        let width = ceil(string.size().width)
        let inline = !shown.isEmpty && !shown.contains(where: \.isNewline) && width <= limit
        inlineWidth = inline ? width + ceil(NSAttributedString(string: " ", attributes: [.font: font]).size().width) : nil
        ascent = ceil(font.ascender)
        text = inline ? nil : NSTextField(wrappingLabelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: ceil(font.ascender - font.descender)))
        let label = "Removed by \(writer.name): \(shown)"
        if let text {
            text.attributedStringValue = string
            text.isSelectable = false
            text.setAccessibilityLabel(label)
            addSubview(text)
        } else {
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Ghost is built in code")
    }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat {
        guard let text else { return frame.height }
        text.preferredMaxLayoutWidth = width
        return ceil(text.fittingSize.height)
    }

    override func layout() {
        super.layout()
        text?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        if text == nil { string.draw(at: .zero) }
    }
}

/// "Two versions of this paragraph": your text stays editable above it; the other version shows here as a ghost
/// block, with Keep Yours, Use Claude's and Keep Both, the default.
@MainActor
final class ConflictCard: NSView, Hanging {
    private let stack = NSStackView()
    private let theirs: NSTextField
    private static let padding: CGFloat = 12
    let keepYours: NSButton
    let useTheirs: NSButton
    let keepBoth: NSButton

    init(_ writer: MarkWriter, theirs text: String, decide: @escaping (ChangeEngine.Decision) -> Void) {
        let shown = text.hasSuffix("\n") ? String(text.dropLast()) : text
        theirs = NSTextField(wrappingLabelWithString: shown)
        theirs.font = ThemeStore.shared.bodyFont
        theirs.textColor = ThemeStore.shared.color(.ink2)
        theirs.isSelectable = true
        theirs.setAccessibilityLabel("\(writer.name)'s version: \(shown)")
        keepYours = ActionButton("Keep Yours", shortcut: "⌥⌘⌫", label: "Keep your version") { decide(.keep) }
        useTheirs = ActionButton("Use \(writer.dashed ? "Other" : writer.possessive)", label: "Use \(writer.possessive) version") {
            decide(.other)
        }
        keepBoth = ActionButton("Keep Both", prominent: true, shortcut: "⌘↩", label: "Keep both versions") { decide(.both) }
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Two versions of this paragraph")

        let title = label("Two versions of this paragraph", size: 13, weight: .semibold, color: .ink)
        let stamp = NSTextField(labelWithAttributedString: writer.stamp)
        let buttons = NSStackView(views: [keepYours, useTheirs, keepBoth])
        buttons.spacing = 8
        let waits = label("Saving waits until you choose.", size: 11, color: .ink2)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in [title, stamp, theirs, buttons, waits] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(10, after: theirs)
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ConflictCard is built in code")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        paint(layer, in: self, radius: 8)
    }

    /// The other version's text, as the card shows it.
    var otherVersion: String {
        theirs.stringValue
    }

    func height(for width: CGFloat) -> CGFloat {
        theirs.preferredMaxLayoutWidth = width - 2 * Self.padding
        return ceil(stack.fittingSize.height)
    }
}
