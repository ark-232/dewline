import Foundation

/// The Format menu's commands and Move Line, as edits to the markdown text: each turns the text and the selection
/// into one replacement and the selection after it.
enum MarkdownFormat: Int, CaseIterable {
    case bold = 1, italic, strikethrough, highlight, code, link
    case heading1, heading2, heading3, heading4, heading5, heading6, body
    case quote, bulletedList, numberedList, task
    case moveLineUp, moveLineDown

    struct Edit: Equatable {
        /// The range replaced, in the text before the edit.
        let range: NSRange
        let replacement: String
        /// The selection after the edit.
        let selection: NSRange
    }

    /// The menu item's title and the undo action's name.
    var name: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        case .code: "Inline Code"
        case .link: "Link"
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6: "Heading \(headingLevel)"
        case .body: "Body Text"
        case .quote: "Quote"
        case .bulletedList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .task: "Task"
        case .moveLineUp: "Move Line Up"
        case .moveLineDown: "Move Line Down"
        }
    }

    private var headingLevel: Int {
        rawValue - MarkdownFormat.heading1.rawValue + 1
    }

    /// The edit this command makes, or nil when it changes nothing.
    func edit(in text: NSString, selection: NSRange) -> Edit? {
        switch self {
        case .bold: wrap(text, selection, "*", 2)
        case .italic: wrap(text, selection, "*", 1)
        case .strikethrough: wrap(text, selection, "~", 2)
        case .highlight: wrap(text, selection, "=", 2)
        case .code: wrap(text, selection, "`", 1)
        case .link: link(text, selection)
        case .moveLineUp, .moveLineDown: moveLines(text, selection)
        default: formatLines(text, selection)
        }
    }

    /// Wraps the selection, or the word at the caret, in `count` of `mark` on each side, or removes them when they are
    /// already there, inside or just outside it. A caret outside any word gets an empty pair. Emphasis takes an odd
    /// run of asterisks, so `***both***` is italic and bold and `**bold**` is not italic.
    private func wrap(_ text: NSString, _ selection: NSRange, _ mark: Character, _ count: Int) -> Edit {
        let character = mark.utf16.first!
        let target = selection.length > 0 ? trimmed(selection, in: text) : word(at: selection.location, in: text)
        let start = target.location
        let end = NSMaxRange(target)
        func run(from index: Int, by step: Int, while inside: (Int) -> Bool) -> Int {
            var length = 0
            while inside(index + step * length), text.character(at: index + step * length) == character { length += 1 }
            return length
        }
        let innerStart = run(from: start, by: 1) { $0 < end }
        let innerEnd = run(from: end - 1, by: -1) { $0 >= start + innerStart }
        let outerStart = run(from: start - 1, by: -1) { $0 >= 0 }
        let outerEnd = run(from: end, by: 1) { $0 < text.length }
        let runs = min(outerStart + innerStart, innerEnd + outerEnd)
        let present = count == 1 && mark == "*" ? runs % 2 == 1 : runs >= count
        let pair = String(repeating: mark, count: count)
        guard present else {
            let selected = selection.length > 0 ? NSRange(location: start + count, length: target.length) : NSRange(location: selection.location + count, length: 0)
            return Edit(range: target, replacement: pair + text.substring(with: target) + pair, selection: selected)
        }
        let opening = start + innerStart - count
        let closing = end - innerEnd
        let inner = NSRange(location: opening + count, length: closing - opening - count)
        let caret = selection.location - min(max(selection.location - opening, 0), count)
        return Edit(
            range: NSRange(location: opening, length: closing + count - opening), replacement: text.substring(with: inner),
            selection: selection.length > 0 ? NSRange(location: opening, length: inner.length) : NSRange(location: min(caret, closing - count), length: 0))
    }

    /// Wraps the selection, or the word at the caret, as `[text]()` with the caret between the parentheses, or an empty
    /// `[]()` with the caret between the brackets. Inside a link, it leaves the link's text and selects it.
    private func link(_ text: NSString, _ selection: NSRange) -> Edit {
        let line = Self.lines(in: text, selection: NSRange(location: selection.location, length: 0))[0]
        for match in Self.inlineLink.matches(in: text.substring(with: line), range: NSRange(location: 0, length: line.length)) {
            let link = NSRange(location: line.location + match.range.location, length: match.range.length)
            let content = NSRange(location: line.location + match.range(at: 1).location, length: match.range(at: 1).length)
            if NSUnionRange(link, selection) == link {
                return Edit(range: link, replacement: text.substring(with: content), selection: NSRange(location: link.location, length: content.length))
            }
        }
        let target = selection.length > 0 ? trimmed(selection, in: text) : word(at: selection.location, in: text)
        let caret = target.length > 0 ? NSMaxRange(target) + 3 : target.location + 1
        return Edit(range: target, replacement: "[\(text.substring(with: target))]()", selection: NSRange(location: caret, length: 0))
    }

    private static let inlineLink = try! NSRegularExpression(pattern: "(?<!!)\\[([^\\]\\r\\n]+)\\]\\([^)\\s]*\\)")

    /// One line's block markers: indentation, quote markers, then a heading's hashes or a list item's marker and task box.
    private static let block = try! NSRegularExpression(
        pattern: "^([ \\t]*)((?:>[ \\t]?)*)([ \\t]*)(?:(#{1,6})(?:[ \\t]+|$)|([-*+]|[0-9]{1,9}[.)])(?:[ \\t]+|$)(\\[[ xX]\\](?:[ \\t]+|$))?)?")

    /// Sets or clears a block format on each selected line. When every selected line has it, it comes off them all;
    /// otherwise the lines without it get it, and a numbered list numbers every line from 1. Blank lines are left alone
    /// unless the selection is on one line.
    private func formatLines(_ text: NSString, _ selection: NSRange) -> Edit? {
        var lines = Self.lines(in: text, selection: selection)
        if lines.count > 1 {
            lines = lines.filter { text.substring(with: $0).contains { !$0.isWhitespace } }
        }
        let parsed = lines.map { line -> (line: NSRange, match: NSTextCheckingResult) in
            let match = Self.block.firstMatch(in: text.substring(with: line), range: NSRange(location: 0, length: line.length))!
            return (line, match)
        }
        func part(_ group: Int, of match: NSTextCheckingResult, in line: NSRange) -> String? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : text.substring(with: NSRange(location: line.location + range.location, length: range.length))
        }
        func has(_ match: NSTextCheckingResult, _ line: NSRange) -> Bool {
            let list = part(5, of: match, in: line)
            let task = part(6, of: match, in: line) != nil
            switch self {
            case .quote: return !part(2, of: match, in: line)!.isEmpty
            case .bulletedList: return list.map { "-*+".contains($0) } == true && !task
            case .numberedList: return list.map { !"-*+".contains($0) } == true && !task
            case .task: return task
            case .body: return false
            default: return part(4, of: match, in: line)?.count == headingLevel
            }
        }
        let removes = !parsed.isEmpty && parsed.allSatisfy { has($0.match, $0.line) }
        var number = 0
        var changes: [(location: Int, length: Int, prefix: String)] = []
        for (line, match) in parsed where removes || self == .numberedList || !has(match, line) {
            let indent = part(1, of: match, in: line)!
            let quotes = part(2, of: match, in: line)!
            let inner = part(3, of: match, in: line)!
            let prefix: String
            switch self {
            case .quote where removes:
                let rest = match.range(at: 3).location
                prefix = indent + text.substring(with: NSRange(location: line.location + rest, length: match.range.length - rest))
            case .quote:
                prefix = "> " + text.substring(with: NSRange(location: line.location, length: match.range.length))
            case .body:
                prefix = indent + inner
            case _ where removes:
                prefix = indent + quotes + inner
            case .bulletedList:
                prefix = indent + quotes + inner + "- "
            case .numberedList:
                number += 1
                prefix = indent + quotes + inner + "\(number). "
            case .task:
                prefix = indent + quotes + inner + "- [ ] "
            default:
                prefix = indent + quotes + inner + String(repeating: "#", count: headingLevel) + " "
            }
            if prefix != text.substring(with: NSRange(location: line.location, length: match.range.length)) {
                changes.append((line.location, match.range.length, prefix))
            }
        }
        guard let first = changes.first, let last = changes.last else { return nil }
        var replacement = ""
        var cursor = first.location
        for change in changes {
            replacement += text.substring(with: NSRange(location: cursor, length: change.location - cursor)) + change.prefix
            cursor = change.location + change.length
        }
        func moved(_ offset: Int) -> Int {
            var shift = 0
            for change in changes where offset >= change.location {
                guard offset >= change.location + change.length else { return change.location + shift + change.prefix.utf16.count }
                shift += change.prefix.utf16.count - change.length
            }
            return offset + shift
        }
        return Edit(
            range: NSRange(location: first.location, length: last.location + last.length - first.location), replacement: replacement,
            selection: Self.range(moved(selection.location), moved(NSMaxRange(selection))))
    }

    /// Swaps the selected lines with the line above or below; the selection stays on the moved text. A last line with no
    /// line ending trades endings with the line it passes.
    private func moveLines(_ text: NSString, _ selection: NSRange) -> Edit? {
        let lines = Self.lines(in: text, selection: selection)
        let block = NSUnionRange(text.paragraphRange(for: lines.first!), text.paragraphRange(for: lines.last!))
        guard block.length > 0 else { return nil }
        let above: NSRange, below: NSRange
        if self == .moveLineUp {
            guard block.location > 0 else { return nil }
            (above, below) = (text.paragraphRange(for: NSRange(location: block.location - 1, length: 0)), block)
        } else {
            guard NSMaxRange(block) < text.length else { return nil }
            (above, below) = (block, text.paragraphRange(for: NSRange(location: NSMaxRange(block), length: 0)))
        }
        func contentsEnd(_ range: NSRange) -> Int {
            var end = 0
            text.getParagraphStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            return end
        }
        let aboveContents = NSRange(location: above.location, length: contentsEnd(above) - above.location)
        let ending = text.substring(with: NSRange(location: NSMaxRange(aboveContents), length: NSMaxRange(above) - NSMaxRange(aboveContents)))
        let endsText = contentsEnd(below) == NSMaxRange(below)
        let lower = endsText ? text.substring(with: below) + ending : text.substring(with: below)
        let upper = endsText ? text.substring(with: aboveContents) : text.substring(with: above)
        let moved = self == .moveLineUp ? above.location - below.location : (lower as NSString).length
        let end = NSMaxRange(NSUnionRange(above, below))
        return Edit(
            range: NSUnionRange(above, below), replacement: lower + upper,
            selection: Self.range(selection.location + moved, min(NSMaxRange(selection) + moved, end)))
    }

    /// The paragraphs the selection touches, without their line endings; a selection that ends at the start of a line
    /// leaves that line out.
    private static func lines(in text: NSString, selection: NSRange) -> [NSRange] {
        let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        var lines: [NSRange] = []
        var location = text.paragraphRange(for: NSRange(location: selection.location, length: 0)).location
        repeat {
            var end = 0
            var contentsEnd = 0
            text.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append(NSRange(location: location, length: contentsEnd - location))
            location = end
        } while location <= last && location < text.length
        return lines
    }

    private func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, Self.isSpace(text.character(at: start)) { start += 1 }
        while end > start, Self.isSpace(text.character(at: end - 1)) { end -= 1 }
        return start < end ? Self.range(start, end) : range
    }

    /// The word around the caret, which is empty when no letter or digit touches it.
    private func word(at location: Int, in text: NSString) -> NSRange {
        func isWordCharacter(_ index: Int) -> Bool {
            Unicode.Scalar(text.character(at: index)).map { CharacterSet.alphanumerics.contains($0) } ?? false
        }
        var start = location
        var end = location
        while start > 0, isWordCharacter(start - 1) { start -= 1 }
        while end < text.length, isWordCharacter(end) { end += 1 }
        return Self.range(start, end)
    }

    private static func isSpace(_ character: unichar) -> Bool {
        Unicode.Scalar(character).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    private static func range(_ start: Int, _ end: Int) -> NSRange {
        NSRange(location: start, length: end - start)
    }
}
