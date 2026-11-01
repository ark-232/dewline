import AppKit

/// Fenced code in Live: the block sits in a `codeBackground` well, and its fence lines shrink to the well's top and
/// bottom padding, hidden, while the selection is off them. A folded block keeps its fences. A Mermaid block is
/// `RenderedBlocks`'.
@MainActor
final class CodeFences {
    private let map: BlockMap
    /// The blocks whose fence lines show, by their fenced span's range.
    private var revealed: Set<NSRange> = []
    private var indented: [NSParagraphStyle: NSParagraphStyle] = [:]
    /// The well's padding: a hidden fence line's height and the room on each side of the code.
    static let padding: CGFloat = 12
    static let radius: CGFloat = 8
    private static let hiddenLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = padding
        style.maximumLineHeight = padding
        return style
    }()

    init(map: BlockMap) {
        self.map = map
    }

    /// Moves the revealed blocks past an edit the map has taken.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { range in
            if NSMaxRange(range) < edited.location { return range }
            return range.location > oldEnd ? NSRange(location: range.location + delta, length: range.length) : nil
        })
    }

    /// The blocks whose fence lines the selection reached or left since they were last styled.
    func revealChanges(_ selection: [NSRange], in text: NSString) -> [NSRange] {
        var now: Set<NSRange> = []
        for range in selection {
            for block in map.blocks(touching: range) {
                for fence in Self.fences(block) where Self.lines(fence, in: text).contains(where: { Self.touches($0, selection) }) {
                    now.insert(fence.range)
                }
            }
        }
        return Array(now.symmetricDifference(revealed))
    }

    /// Styles the fenced code in `styled`, a copy of the storage from `offset` on, for a selection in its coordinates.
    /// `folds` are in the storage's.
    func style(_ styled: NSMutableAttributedString, at offset: Int, selection: [NSRange], folds: [NSRange]) {
        let whole = NSRange(location: offset, length: styled.length)
        revealed = revealed.filter { !NSLocationInRange($0.location, whole) }
        let text = styled.mutableString
        for block in map.blocks(in: whole) {
            for fence in Self.fences(block) {
                let local = fence.shifted(by: -offset)
                guard local.range.location >= 0, NSMaxRange(local.range) <= styled.length else { continue }
                let well = text.paragraphRange(for: local.range)
                styled.addAttribute(.dewlineCode, value: fence.range.location, range: well)
                styled.enumerateAttribute(.paragraphStyle, in: well) { value, run, _ in
                    styled.addAttribute(.paragraphStyle, value: indent(value as? NSParagraphStyle ?? .default), range: run)
                }
                let lines = Self.lines(local, in: text)
                if lines.contains(where: { Self.touches($0, selection) }) || folds.contains(where: { NSIntersectionRange($0, fence.range).length > 0 }) {
                    revealed.insert(fence.range)
                    for line in lines { styled.addAttribute(.foregroundColor, value: ThemeStore.shared.color(.syntax), range: line) }
                    continue
                }
                for line in lines {
                    let paragraph = text.paragraphRange(for: line)
                    styled.addAttributes([
                        .font: MarkdownStyler.hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: Self.hiddenLine,
                    ], range: paragraph)
                }
            }
        }
    }

    /// `style` with the well's padding on both sides.
    private func indent(_ style: NSParagraphStyle) -> NSParagraphStyle {
        if let indented = indented[style] { return indented }
        let wider = style.mutableCopy() as! NSMutableParagraphStyle
        wider.firstLineHeadIndent += Self.padding
        wider.headIndent += Self.padding
        wider.tailIndent = -Self.padding
        indented[style] = wider
        return wider
    }

    /// A code block's fenced spans, in the document, outside rendered blocks.
    private static func fences(_ block: BlockMap.Block) -> [SyntaxSpan] {
        guard block.kind == .code else { return [] }
        return block.spans.filter { span in
            span.kind == .fencedCode && !block.rendered.contains { NSIntersectionRange($0.range, span.range).length > 0 }
        }.map { $0.shifted(by: block.range.location) }
    }

    /// The fence lines of `fence`, without their line breaks: the opening one, and the closing one when it is closed.
    private static func lines(_ fence: SyntaxSpan, in text: NSString) -> [NSRange] {
        func line(_ at: Int) -> NSRange {
            var (start, end, contentsEnd) = (0, 0, 0)
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(at, text.length), length: 0))
            return NSRange(location: start, length: contentsEnd - start)
        }
        let opening = line(fence.range.location)
        guard NSMaxRange(fence.content) < NSMaxRange(fence.range) else { return [opening] }
        let closing = line(NSMaxRange(fence.content))
        return closing == opening ? [opening] : [opening, closing]
    }

    private static func touches(_ range: NSRange, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }
}

extension EditorTextView {
    /// Fills each fenced code block in `visible` with its well.
    func drawCodeWells(in visible: NSRange, line: (Int) -> NSRect) {
        let storage = textStorage!
        let padding = textContainer?.lineFragmentPadding ?? 0
        let left = textContainerOrigin.x + padding
        let width = (textContainer?.size.width ?? 0) - 2 * padding
        var drawn = Set<Int>()
        ThemeStore.shared.color(.codeBackground).setFill()
        storage.enumerateAttribute(.dewlineCode, in: visible) { value, range, _ in
            guard value != nil else { return }
            var whole = NSRange()
            storage.attribute(.dewlineCode, at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            guard drawn.insert(whole.location).inserted else { return }
            let top = line(whole.location)
            let bottom = line(max(NSMaxRange(whole) - 1, whole.location))
            let well = NSRect(x: left, y: top.minY, width: width, height: bottom.maxY - top.minY)
            NSBezierPath(roundedRect: well, xRadius: CodeFences.radius, yRadius: CodeFences.radius).fill()
        }
    }
}

extension NSAttributedString.Key {
    /// A fenced code block's lines, with the block's start, so neighboring blocks stay apart.
    static let dewlineCode = NSAttributedString.Key("DewlineCode")
}
