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
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = ThemeStore.shared.color(color)
    return label
}

/// A push button that calls `action` when clicked.
@MainActor
private final class ActionButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(_ title: String, prominent: Bool = false, shortcut: String? = nil, label: String, _ action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(clicked)
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: prominent ? .semibold : .regular)
        if prominent { bezelColor = ThemeStore.shared.color(.accent) }
        toolTip = shortcut.map { "\(title) (\($0))" }
        setAccessibilityLabel(label)
    }

    @objc private func clicked() {
        handler()
    }
}

/// Removed text, struck, at ink 42% with the strike in the writer's color.
@MainActor
final class Ghost: NSView, Hanging {
    private let text = NSTextField(wrappingLabelWithString: "")

    init(_ removed: String, writer: MarkWriter) {
        super.init(frame: .zero)
        let shown = removed.hasSuffix("\n") ? String(removed.dropLast()) : removed
        text.attributedStringValue = NSAttributedString(string: shown, attributes: [
            .font: ThemeStore.shared.bodyFont,
            .foregroundColor: ThemeStore.shared.color(.ink).withAlphaComponent(0.42),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: writer.color,
        ])
        text.isSelectable = false
        text.setAccessibilityLabel("Removed by \(writer.name): \(shown)")
        addSubview(text)
    }

    required init?(coder: NSCoder) {
        fatalError("Ghost is built in code")
    }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat {
        text.preferredMaxLayoutWidth = width
        return ceil(text.fittingSize.height)
    }

    override func layout() {
        super.layout()
        text.frame = bounds
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

/// The opaque strip under the change at the caret: the writer's dot and stamp, Keep (Cmd-Return) and Revert
/// (Option-Cmd-Delete).
@MainActor
final class ChangeBar: NSView {
    private let stack = NSStackView()
    private let dot = NSView()
    private let stamp = NSTextField(labelWithString: "")
    private var act: (Bool) -> Void = { _ in }
    private(set) var writer: MarkWriter?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        let keep = ActionButton("Keep", prominent: true, shortcut: "⌘↩", label: "Keep this change") { [weak self] in self?.act(true) }
        let revert = ActionButton("Revert", shortcut: "⌥⌘⌫", label: "Revert this change") { [weak self] in self?.act(false) }
        for view in [dot, stamp, keep, revert] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(6, after: dot)
        stack.setCustomSpacing(14, after: stamp)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ChangeBar is built in code")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        paint(layer, in: self, radius: 16)
        dot.layer?.backgroundColor = writer?.color.resolved(for: effectiveAppearance).cgColor
    }

    /// Shows `writer`'s change; `act` gets true for Keep and false for Revert.
    func show(_ writer: MarkWriter, act: @escaping (Bool) -> Void) {
        self.act = act
        guard writer != self.writer else { return }
        self.writer = writer
        stamp.attributedStringValue = writer.stamp
        setAccessibilityLabel("\(writer.name) changed this")
        needsDisplay = true
    }
}
