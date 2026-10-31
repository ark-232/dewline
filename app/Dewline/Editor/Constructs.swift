import AppKit

/// The constructs past CommonMark: highlights, comments, tags, footnote references, wikilinks, embeds and callouts.
/// The styler hides and reveals their markers; this styles what shows.
@MainActor
enum Constructs {
    private static var superscripts: [NSFont: NSFont] = [:]
    private static var washes: [NSColor: NSColor] = [:]
    private static var titleStyles: [NSParagraphStyle: NSParagraphStyle] = [:]
    /// The room a callout's title line leaves for its icon.
    static let iconSpace: CGFloat = 24

    /// Styles `span`, in the coordinates of `styled`.
    static func style(_ span: SyntaxSpan, in styled: NSMutableAttributedString, source: Bool) {
        let store = ThemeStore.shared
        switch span.kind {
        case .highlight:
            let rule = store.color(.quoteRule)
            let wash = washes[rule] ?? rule.withAlphaComponent(0.3)
            washes[rule] = wash
            styled.addAttribute(.backgroundColor, value: wash, range: span.content)
        case .comment:
            styled.addAttribute(.foregroundColor, value: store.color(.ink2), range: span.content)
        case .footnoteReference:
            styled.addAttribute(.foregroundColor, value: store.color(.link), range: span.content)
            guard !source else { return }
            styled.enumerateAttribute(.font, in: span.content) { value, run, _ in
                let font = value as! NSFont
                let small = superscripts[font] ?? NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * 0.7).rounded())!
                superscripts[font] = small
                styled.addAttributes([.font: small, .baselineOffset: (font.pointSize * 0.35).rounded()], range: run)
            }
        case .wikiLink, .embed:
            styled.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: store.color(.link), .backgroundColor: store.color(.codeBackground),
            ], range: span.content)
        default:
            break
        }
    }

    /// Tags are dim tokens whose `#` stays. A callout's lines carry its type for the view to draw, its title line
    /// leaves room for the icon, and the title is bold. `lines` is the block in the coordinates of `styled`.
    static func style(_ block: BlockMap.Block, lines: NSRange, in styled: NSMutableAttributedString, source: Bool) {
        let store = ThemeStore.shared
        for tag in block.spans where tag.kind == .tag {
            styled.addAttributes(
                [.foregroundColor: store.color(.ink2), .backgroundColor: store.color(.codeBackground)], range: tag.shifted(by: lines.location).range
            )
        }
        guard block.kind == .callout, !source, let callout = block.spans.first(where: { $0.kind == .callout }) else { return }
        let text = styled.mutableString
        let marker = callout.shifted(by: lines.location)
        styled.addAttribute(.dewlineCallout, value: text.substring(with: marker.content).lowercased(), range: lines)
        var (start, end, contentsEnd) = (0, 0, 0)
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: marker.range.location, length: 0))
        let title = NSRange(location: NSMaxRange(marker.range), length: max(contentsEnd - NSMaxRange(marker.range), 0))
        styled.enumerateAttribute(.font, in: title) { value, run, _ in
            styled.addAttribute(.font, value: store.font(value as! NSFont, adding: .bold), range: run)
        }
        let quote = store.quoteParagraphStyle
        let style = titleStyles[quote] ?? {
            let style = quote.mutableCopy() as! NSMutableParagraphStyle
            style.firstLineHeadIndent += iconSpace
            style.headIndent += iconSpace
            return style
        }()
        titleStyles[quote] = style
        styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: end - start))
    }

    /// A callout's icon and color by type, with Obsidian's aliases; an unknown type looks like a note.
    static func look(_ type: String) -> (symbol: String, color: NSColor) {
        switch type {
        case "abstract", "summary", "tldr": ("list.bullet.clipboard", .systemTeal)
        case "info": ("info.circle", .systemBlue)
        case "todo": ("checkmark.circle", .systemBlue)
        case "tip", "hint", "important": ("flame", .systemCyan)
        case "success", "check", "done": ("checkmark", .systemGreen)
        case "question", "help", "faq": ("questionmark.circle", .systemYellow)
        case "warning", "caution", "attention": ("exclamationmark.triangle", .systemOrange)
        case "failure", "fail", "missing": ("xmark", .systemRed)
        case "danger", "error": ("bolt", .systemRed)
        case "bug": ("ladybug", .systemRed)
        case "example": ("list.bullet", .systemPurple)
        case "quote", "cite": ("quote.opening", .systemGray)
        default: ("pencil", .systemBlue)
        }
    }
}

extension EditorTextView {
    /// Fills each callout in `visible` with the code well and draws its type's icon before the title.
    func drawCallouts(in visible: NSRange, line: (Int) -> NSRect) {
        let storage = textStorage!
        let padding = textContainer?.lineFragmentPadding ?? 0
        let left = textContainerOrigin.x + padding
        let width = (textContainer?.size.width ?? 0) - 2 * padding
        var drawn = Set<Int>()
        storage.enumerateAttribute(.dewlineCallout, in: visible) { value, range, _ in
            guard let type = value as? String else { return }
            var whole = NSRange()
            storage.attribute(.dewlineCallout, at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            guard drawn.insert(whole.location).inserted else { return }
            let top = line(whole.location)
            let bottom = line(max(NSMaxRange(whole) - 1, whole.location))
            ThemeStore.shared.color(.codeBackground).setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: top.minY, width: width, height: bottom.maxY - top.minY), xRadius: 6, yRadius: 6).fill()
            let look = Constructs.look(type)
            let size = ThemeStore.shared.bodyFont.pointSize * 0.85
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [look.color]))
            guard let icon = NSImage(systemSymbolName: look.symbol, accessibilityDescription: type)?.withSymbolConfiguration(configuration) else { return }
            let indent = ThemeStore.shared.quoteParagraphStyle.firstLineHeadIndent
            icon.draw(in: NSRect(
                x: left + indent + (Constructs.iconSpace - icon.size.width) / 2 - 2, y: top.midY - icon.size.height / 2,
                width: icon.size.width, height: icon.size.height
            ))
        }
    }
}

extension NSAttributedString.Key {
    /// A callout's lines, with its type in lowercase.
    static let dewlineCallout = NSAttributedString.Key("DewlineCallout")
}
