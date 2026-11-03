import AppKit
import MdCore

/// A view that hangs under a paragraph in space the styler reserves for it.
@MainActor
protocol Hanging: NSView {
    func height(for width: CGFloat) -> CGFloat
}

@MainActor
private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: Token) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Chrome.brand(size, weight: weight == .semibold ? 600 : 450)
    label.textColor = ThemeStore.shared.color(color)
    return label
}

/// A button that calls `action` when clicked: the prominent one filled with ink and set in paper, the others bare text
/// in `ink2`.
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
            .font: NSFont.systemFont(ofSize: 13, weight: prominent ? .medium : .regular),
            .foregroundColor: ThemeStore.shared.color(prominent ? .paper : .ink2),
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

/// "Two versions of this paragraph": your text stays editable above it; the other version shows here under "From
/// git" or "From another app", with Keep Yours (the default, ⌥⌘⌫), Use git’s (⌘↩) and Keep Both.
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
        keepYours = ActionButton("Keep Yours", prominent: true, shortcut: "\u{2325}\u{2318}\u{232B}", label: "Keep your version") { decide(.keep) }
        useTheirs = ActionButton(Self.useTheirs(writer), shortcut: "\u{2318}\u{21A9}", label: Self.useTheirs(writer)) { decide(.other) }
        keepBoth = ActionButton("Keep Both", label: "Keep both versions") { decide(.both) }
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Two versions of this paragraph")

        let title = label("Two versions of this paragraph", size: 13, weight: .semibold, color: .ink)
        let stamp = label(Self.from(writer), size: 13, color: .ink2)
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

    /// A 1 pt rule around paper, no shadow.
    override func updateLayer() {
        guard let layer else { return }
        let store = ThemeStore.shared
        layer.backgroundColor = store.color(.paper).resolved(for: effectiveAppearance).cgColor
        layer.borderColor = store.color(.ink).resolved(for: effectiveAppearance).withAlphaComponent(effectiveAppearance.isDark ? 0.16 : 0.10).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 8
    }

    /// "From git", "From another app", "From Claude".
    static func from(_ writer: MarkWriter) -> String {
        writer.dashed ? "From another app" : "From \(writer.name)"
    }

    /// "Use git\u{2019}s", "Use the other version".
    static func useTheirs(_ writer: MarkWriter) -> String {
        writer.dashed ? "Use the other version" : "Use \(writer.name)\u{2019}s"
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
