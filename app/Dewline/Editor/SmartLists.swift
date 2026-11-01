import AppKit

/// A list item from the block map's tokens, in document offsets.
struct ListItem {
    /// From the start of the marker's line to the marker.
    let indent: NSRange
    /// The bullet or number and the blanks after it.
    let marker: NSRange
    /// After the marker and any task box with its blank.
    let content: Int
    let isTask: Bool
    /// The indent of the item holding this one.
    let parentIndent: Int?
}

extension EditorTextView {
    /// The innermost list item holding `offset`, past its marker. Items in quotes and code are left alone.
    func listItem(at offset: Int) -> ListItem? {
        let text = textStorage!.mutableString
        // An item holds the offsets from its marker to the end of its last line, before the line break.
        let spans = styler.map.blocks(touching: NSRange(location: offset, length: 0)).filter { $0.kind == .item }
            .flatMap { block in block.spans.map { $0.shifted(by: block.range.location) } }
        let holding = spans.filter { span in
            var end = NSMaxRange(span.range)
            while end > span.range.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
            return span.kind == .item && span.range.location <= offset && offset <= end
        }
        guard let item = holding.max(by: { $0.range.location < $1.range.location }), let marker = item.markers.first else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: item.range.location, length: 0)).location
        var content = NSMaxRange(marker)
        let task = spans.first { span in
            if case .taskBox = span.kind { return span.range.location == content }
            return false
        }
        if let task {
            content = NSMaxRange(task.range)
            if content < text.length, text.character(at: content) == 0x20 { content += 1 }
        }
        guard offset >= content else { return nil }
        let parent = holding.filter { $0.range.location < item.range.location }.max { $0.range.location < $1.range.location }
        return ListItem(
            indent: NSRange(location: lineStart, length: item.range.location - lineStart),
            marker: marker,
            content: content,
            isTask: task != nil,
            parentIndent: parent.map { $0.range.location - text.lineRange(for: NSRange(location: $0.range.location, length: 0)).location }
        )
    }

    /// Return in a list item starts the next item, numbered one on and unchecked; Return on an empty item ends the
    /// list. Returns false when the caret is not in an item.
    func continueList() -> Bool {
        let text = textStorage!.mutableString
        let selection = selectedRange()
        guard let item = listItem(at: selection.location) else { return false }
        var contentsEnd = 0
        var lineEnd = 0
        text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: item.marker.location, length: 0))
        let rest = text.substring(with: NSRange(location: item.content, length: max(contentsEnd - item.content, 0)))
        // A task box with nothing after it may not parse as one.
        let bare = rest.trimmingCharacters(in: .whitespaces)
        if selection.length == 0, selection.location <= contentsEnd, bare.isEmpty || ["[ ]", "[x]", "[X]"].contains(bare) {
            replace(NSRange(location: item.indent.location, length: contentsEnd - item.indent.location), with: "")
            return true
        }
        let marker = text.substring(with: item.marker)
        let bullet = marker.trimmingCharacters(in: .whitespaces)
        let blanks = String(marker.dropFirst(bullet.count))
        var next = bullet
        if let number = Int(bullet.prefix { $0.isNumber }) {
            next = "\(number + 1)" + bullet.drop { $0.isNumber }
        }
        let indent = text.substring(with: item.indent)
        var newline = text.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
        if newline.isEmpty {
            // The last line: its neighbor above gives the line ending.
            newline = "\n"
            if item.indent.location > 0 {
                var above = 0
                var aboveEnd = 0
                text.getLineStart(nil, end: &aboveEnd, contentsEnd: &above, for: NSRange(location: item.indent.location - 1, length: 0))
                if aboveEnd > above { newline = text.substring(with: NSRange(location: above, length: aboveEnd - above)) }
            }
        }
        replace(selection, with: newline + (indent.allSatisfy(\.isWhitespace) ? indent : String(repeating: " ", count: indent.count)) + next + blanks + (item.isTask ? "[ ] " : ""))
        return true
    }

    /// Tab indents and Shift-Tab outdents every item whose marker line meets the selection, as one edit. Returns false
    /// when no item does.
    func indentItems(outdent: Bool) -> Bool {
        let text = textStorage!.mutableString
        let selection = selectedRange()
        let lines = text.lineRange(for: selection)
        var edits: [(range: NSRange, string: String)] = []
        var line = lines.location
        repeat {
            let range = text.lineRange(for: NSRange(location: line, length: 0))
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: range)
            if let item = listItem(at: contentsEnd), item.indent.location == range.location {
                if outdent {
                    let keep = min(item.parentIndent ?? 0, item.indent.length)
                    if keep < item.indent.length {
                        edits.append((NSRange(location: item.indent.location + keep, length: item.indent.length - keep), ""))
                    }
                } else {
                    edits.append((NSRange(location: item.indent.location, length: 0), String(repeating: " ", count: item.marker.length)))
                }
            }
            line = NSMaxRange(range)
        } while line < NSMaxRange(lines)
        guard !edits.isEmpty else { return listItem(at: selection.location) != nil }
        let changed = NSRange(location: edits[0].range.location, length: NSMaxRange(edits.last!.range) - edits[0].range.location)
        let result = NSMutableString(string: text.substring(with: changed))
        for edit in edits.reversed() {
            result.replaceCharacters(in: NSRange(location: edit.range.location - changed.location, length: edit.range.length), with: edit.string)
        }
        func moved(_ offset: Int) -> Int {
            edits.reduce(offset) { position, edit in
                guard edit.range.location < offset || (edit.range.length == 0 && edit.range.location == offset) else { return position }
                return position + edit.string.utf16.count - min(edit.range.length, offset - edit.range.location)
            }
        }
        let start = moved(selection.location)
        replace(changed, with: result as String, selecting: NSRange(location: start, length: max(moved(NSMaxRange(selection)) - start, 0)))
        return true
    }

    /// Replaces `range` with `string` as one undoable edit, then selects `selection`, or puts the caret after the
    /// new text.
    func replace(_ range: NSRange, with string: String, selecting selection: NSRange? = nil) {
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage!.replaceCharacters(in: range, with: string)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(selection ?? NSRange(location: range.location + string.utf16.count, length: 0))
    }
}
