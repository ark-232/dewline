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

    /// A callout's glyph and color by type, with Obsidian's aliases; an unknown type looks like a note.
    static func look(_ type: String) -> (glyph: CalloutGlyph, color: NSColor) {
        let store = ThemeStore.shared
        return switch type {
        case "abstract", "summary", "tldr": (.lines, store.color(.signal))
        case "info": (.info, store.color(.signal))
        case "todo": (.todo, store.color(.signal))
        case "tip", "hint", "important": (.bead, store.color(.signal))
        case "success", "check", "done": (.check, store.writerColor(.git))
        case "question", "help", "faq": (.question, store.color(.ink2))
        case "warning", "caution", "attention": (.warning, store.color(.codeNumber))
        case "failure", "fail", "missing": (.cross, store.color(.codeDeleted))
        case "danger", "error": (.bolt, store.color(.codeDeleted))
        case "bug": (.bug, store.color(.codeDeleted))
        case "example": (.lines, store.color(.ink2))
        case "quote", "cite": (.quote, store.color(.ink3))
        default: (.pen, store.color(.signal))
        }
    }
}

/// A callout's 16 pt line glyph at 1.5 pt, drawn like Dewline's chrome glyphs.
enum CalloutGlyph: CaseIterable {
    case pen, info, todo, bead, check, question, warning, cross, bolt, bug, lines, quote

    /// The glyph in a 16 pt square with a flipped y axis; `fill` holds the parts drawn solid.
    var paths: (stroke: NSBezierPath, fill: NSBezierPath) {
        let stroke = NSBezierPath(), fill = NSBezierPath()
        func line(_ points: [(CGFloat, CGFloat)]) {
            stroke.move(to: NSPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { stroke.line(to: NSPoint(x: point.0, y: point.1)) }
        }
        func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat = 1) {
            fill.appendOval(in: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        let ring = NSRect(x: 2, y: 2, width: 12, height: 12)
        switch self {
        case .pen:
            line([(3, 13), (11.5, 4.5)])
            line([(9.75, 2.75), (13.25, 6.25)])
        case .info:
            stroke.appendOval(in: ring)
            line([(8, 7.5), (8, 11)])
            dot(8, 5)
        case .todo:
            stroke.appendOval(in: ring)
            line([(5.5, 8.25), (7.25, 10), (10.5, 6.25)])
        case .bead:
            line([(1.75, 8), (14.25, 8)])
            dot(10, 8, 2.75)
        case .check:
            line([(3, 8.5), (6.5, 12), (13, 4.5)])
        case .question:
            stroke.appendOval(in: ring)
            stroke.move(to: NSPoint(x: 6.25, y: 6.5))
            stroke.curve(to: NSPoint(x: 8, y: 9), controlPoint1: NSPoint(x: 6.25, y: 4), controlPoint2: NSPoint(x: 11.5, y: 5.5))
            dot(8, 11.25, 0.9)
        case .warning:
            line([(8, 2.5), (14, 13), (2, 13), (8, 2.5)])
            line([(8, 6.5), (8, 9.25)])
            dot(8, 11.1, 0.9)
        case .cross:
            line([(4.5, 4.5), (11.5, 11.5)])
            line([(11.5, 4.5), (4.5, 11.5)])
        case .bolt:
            line([(9.5, 2), (4.5, 9), (8.5, 9), (6.5, 14), (11.5, 7), (7.5, 7), (9.5, 2)])
        case .bug:
            stroke.appendOval(in: NSRect(x: 5, y: 4.5, width: 6, height: 9))
            line([(8, 7), (8, 13.5)])
            line([(2.5, 7), (5, 8)])
            line([(13.5, 7), (11, 8)])
            line([(2.5, 12), (5, 11)])
            line([(13.5, 12), (11, 11)])
        case .lines:
            line([(3, 4.5), (13, 4.5)])
            line([(3, 8), (13, 8)])
            line([(3, 11.5), (10, 11.5)])
        case .quote:
            line([(5, 4), (4, 9.5)])
            line([(10, 4), (9, 9.5)])
        }
        stroke.lineWidth = 1.5
        stroke.lineCapStyle = .round
        stroke.lineJoinStyle = .round
        return (stroke, fill)
    }

    /// Draws the glyph into `rect` of a flipped view in `color`.
    func draw(in rect: NSRect, color: NSColor) {
        let (stroke, fill) = paths
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(rect.width / 16)
        stroke.transform(using: transform)
        fill.transform(using: transform)
        color.set()
        stroke.stroke()
        fill.fill()
    }
}

extension EditorTextView {
    /// Fills each callout in `visible` with the code well and draws its type's glyph before the title.
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
            let size = (ThemeStore.shared.bodyFont.pointSize * 0.94).rounded()
            let indent = ThemeStore.shared.quoteParagraphStyle.firstLineHeadIndent
            look.glyph.draw(in: NSRect(x: left + indent + (Constructs.iconSpace - size) / 2 - 2, y: top.midY - size / 2, width: size, height: size), color: look.color)
        }
    }
}

extension NSAttributedString.Key {
    /// A callout's lines, with its type in lowercase.
    static let dewlineCallout = NSAttributedString.Key("DewlineCallout")
}
