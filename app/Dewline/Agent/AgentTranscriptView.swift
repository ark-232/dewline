import AppKit

/// The panel's drawing: SF Pro 13 on the note's paper, ink and ink 2, chrome fills in the code token, hairlines in
/// ink at 12%.
@MainActor
enum AgentLook {
    static var font: NSFont { .systemFont(ofSize: 13) }
    static var small: NSFont { .systemFont(ofSize: 11) }
    static var strong: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    static var mono: NSFont { ThemeStore.shared.codeFont(size: 12) }
    static var paper: NSColor { ThemeStore.shared.color(.paper) }
    static var ink: NSColor { ThemeStore.shared.color(.ink) }
    static var ink2: NSColor { ThemeStore.shared.color(.ink2) }
    static var fill: NSColor { ThemeStore.shared.color(.codeBackground) }
    static var rule: NSColor { ThemeStore.shared.color(.ink).withAlphaComponent(0.12) }

    static func label(_ text: String, font: NSFont = font, color: NSColor = ink) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        return button
    }

    static func symbol(_ name: String, color: NSColor = ink2) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    /// Markdown as the note shows it, sized for the panel: emphasis, code, links and line breaks.
    static func markdown(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let result = NSMutableAttributedString(parsed)
        let whole = NSRange(location: 0, length: result.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        result.addAttributes([.font: font, .foregroundColor: ink, .paragraphStyle: paragraph], range: whole)
        result.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if intent.contains(.code) {
                result.addAttribute(.font, value: mono, range: range)
            } else if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                result.addAttribute(.font, value: NSFont(descriptor: descriptor, size: 13) ?? font, range: range)
            }
        }
        result.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard value != nil else { return }
            result.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: ThemeStore.shared.color(.accent)], range: range)
        }
        return result
    }

    /// `code` spans in mono, the rest plain.
    static func withCode(_ text: String, color: NSColor = ink) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            result.append(NSAttributedString(string: String(part), attributes: [.font: index % 2 == 1 ? mono : font, .foregroundColor: color]))
        }
        return result
    }
}

/// A view that fills a rounded rect, and strokes it when asked; drawn, so its colors follow the appearance.
final class AgentBox: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// `content` inside the box with `inset` on every side.
    static func around(_ content: NSView, inset: NSEdgeInsets, fill: NSColor?, stroke: NSColor? = nil, radius: CGFloat = 8) -> AgentBox {
        let box = AgentBox()
        box.fill = fill
        box.stroke = stroke
        box.radius = radius
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: inset.top),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset.left),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset.right),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset.bottom),
        ])
        return box
    }
}

/// A flipped stack's document view, so the transcript grows downward from the top.
final class AgentFlipped: NSView {
    override var isFlipped: Bool { true }
}

/// The paper behind the panel, and a hairline under the header.
final class AgentPaper: NSView {
    var ruleY: CGFloat?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        AgentLook.paper.setFill()
        bounds.fill()
        if let ruleY {
            AgentLook.rule.setFill()
            NSRect(x: 0, y: ruleY, width: bounds.width, height: 1).fill()
        }
    }
}
