import AppKit

extension BlockMap {
    /// The text a fold of `block` hides: a fenced code block's or a callout's lines after its first, or a heading's
    /// section, the blocks after it up to the next heading of the same or a higher level. Nil for a block that does
    /// not fold or would hide nothing.
    func hidden(by block: Block, in text: NSString) -> NSRange? {
        let first = NSMaxRange(text.lineRange(for: NSRange(location: block.range.location, length: 0)))
        var end = NSMaxRange(block.range)
        switch block.kind {
        case .heading(let level):
            end = first
            walk(from: NSMaxRange(block.range) - 1) { next in
                guard next.range.location >= first else { return true }
                if case .heading(let other) = next.kind, other <= level { return false }
                end = NSMaxRange(next.range)
                return true
            }
        case .code where block.spans.contains { $0.kind == .fencedCode }, .callout:
            break
        default:
            return nil
        }
        return end > first ? NSRange(location: first, length: end - first) : nil
    }

    /// Whether `block` folds, found without walking a heading's section.
    func folds(_ block: Block, in text: NSString) -> Bool {
        guard case .heading(let level) = block.kind else { return hidden(by: block, in: text) != nil }
        var folds = false
        walk(from: NSMaxRange(block.range) - 1) { next in
            guard next.range.location > block.range.location else { return true }
            if case .heading(let other) = next.kind { folds = other > level } else { folds = true }
            return false
        }
        return folds
    }
}

extension EditorTextView {
    /// The block Fold acts on: the fenced code block or callout holding the caret, else the heading over it.
    private var foldTarget: BlockMap.Block? {
        let caret = selectedRange().location
        let map = styler.map
        if let block = map.blocks(in: NSRange(location: caret, length: 0)).first, map.hidden(by: block, in: textStorage!.mutableString) != nil {
            return block
        }
        var heading: BlockMap.Block?
        map.walk(from: caret, backward: true) { block in
            guard case .heading = block.kind else { return true }
            heading = block
            return false
        }
        return heading
    }

    /// Folds `block`, first moving a caret it would hide to the end of the block's first line.
    func fold(_ block: BlockMap.Block) {
        let text = textStorage!.mutableString
        guard let hidden = styler.map.hidden(by: block, in: text) else { return }
        moveOut(of: [hidden])
        styler.setFolds(styler.folds + [hidden])
    }

    /// Moves a selection that meets `hidden` to the end of the visible line above the outermost fold it meets.
    private func moveOut(of hidden: [NSRange]) {
        let selection = selectedRange()
        guard let outer = hidden.filter({ NSIntersectionRange($0, selection).length > 0 || NSLocationInRange(selection.location, $0) })
            .min(by: { $0.location < $1.location || $0.location == $1.location && $0.length > $1.length })
        else { return }
        var end = 0
        textStorage!.mutableString.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: outer.location - 1, length: 0))
        setSelectedRange(NSRange(location: end, length: 0))
    }

    @objc func foldBlock(_ sender: Any?) {
        if let block = foldTarget { fold(block) }
    }

    /// Unfolds the fold under the caret's line, else the fold of the block Fold acts on.
    @objc func unfoldBlock(_ sender: Any?) {
        let text = textStorage!.mutableString
        let lineEnd = NSMaxRange(text.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        let target = foldTarget.flatMap { styler.map.hidden(by: $0, in: text) }
        styler.setFolds(styler.folds.filter { $0.location != lineEnd && $0 != target })
    }

    @objc func foldAll(_ sender: Any?) {
        let text = textStorage!.mutableString
        var hidden: [NSRange] = []
        styler.map.walk(from: -1) { block in
            if let range = styler.map.hidden(by: block, in: text) { hidden.append(range) }
            return true
        }
        moveOut(of: hidden)
        styler.setFolds(hidden)
    }

    @objc func unfoldAll(_ sender: Any?) {
        styler.setFolds([])
    }

    /// The foldable block whose first line holds `point`, and that line's rect.
    func foldable(at point: NSPoint) -> (block: BlockMap.Block, line: NSRect)? {
        let index = characterIndexForInsertion(at: NSPoint(x: point.x, y: max(point.y, textContainerOrigin.y)))
        let text = textStorage!.mutableString
        guard let block = styler.map.blocks(in: NSRange(location: min(index, max(text.length - 1, 0)), length: 0)).first,
            styler.map.folds(block, in: text), let line = lineRect(at: block.range.location), line.minY <= point.y, point.y < line.maxY
        else { return nil }
        return (block, line)
    }

    /// The rect of the line holding the character at `index`, across the view's width.
    func lineRect(at index: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: index),
            let fragment = layout.textLayoutFragment(for: location)
        else { return nil }
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(offset, $0.characterRange) }) ?? fragment.textLineFragments.first
        else { return nil }
        let y = textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
        return NSRect(x: 0, y: y, width: bounds.width, height: line.typographicBounds.height)
    }

    /// Draws a chevron in the left margin beside each folded block, and beside the foldable block under the pointer.
    func drawDisclosures(in rect: NSRect) {
        let text = textStorage!.mutableString
        guard text.length > 0 else { return }
        let first = characterIndexForInsertion(at: NSPoint(x: rect.minX, y: max(rect.minY, textContainerOrigin.y)))
        let last = characterIndexForInsertion(at: NSPoint(x: rect.maxX, y: rect.maxY))
        let visible = NSRange(location: min(first, last), length: abs(last - first))
        let column = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        for block in styler.map.blocks(in: visible) {
            let anchor = NSMaxRange(text.lineRange(for: NSRange(location: block.range.location, length: 0)))
            let folded = styler.folds.contains { $0.location == anchor }
            guard folded || hoveredFold == block.range.location, styler.map.folds(block, in: text), let line = lineRect(at: block.range.location)
            else { continue }
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(.init(paletteColors: [ThemeStore.shared.color(folded ? .ink2 : .syntax)]))
            guard let image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: folded ? "Unfold" : "Fold")?
                .withSymbolConfiguration(configuration)
            else { continue }
            let size = image.size
            let target = NSRect(x: column - 22 - size.width / 2, y: line.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: target.integral, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
