import AppKit

/// GFM tables laid out in place. Outside the selection a row hides its pipes, padding and extra cells, kerns its hidden
/// characters so each cell starts at its column, and draws rules between the columns; the delimiter row hides and
/// draws a rule under the head. A row the selection touches, or the head with its delimiter row, shows its source.
/// Columns are as wide as their widest cell, and only widen while the selection stays in the table.
@MainActor
final class Tables {
    enum Alignment {
        case left, center, right
    }

    private struct Table {
        let head: BlockMap.Block
        let rows: [BlockMap.Block]

        var range: NSRange {
            NSUnionRange(head.range, rows.last?.range ?? head.range)
        }
    }

    private let map: BlockMap
    /// The token ranges of the heads and rows showing their source.
    private var revealed: Set<NSRange> = []
    /// The table holding the selection, by its head's location, and its column widths.
    private var active: (head: Int, widths: [CGFloat])?

    init(map: BlockMap) {
        self.map = map
    }

    /// Moves the revealed rows past an edit the map has taken.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { range in
            if NSMaxRange(range) < edited.location { return range }
            return range.location > oldEnd ? NSRange(location: range.location + delta, length: range.length) : nil
        })
    }

    /// `range` and the whole tables at its ends: a row's columns depend on every row.
    func covering(_ range: NSRange) -> NSRange {
        [range.location, max(NSMaxRange(range) - 1, range.location)].reduce(range) { range, location in
            table(at: location).map { NSUnionRange(range, $0.range) } ?? range
        }
    }

    /// The tables whose rows the selection entered or left since they were last styled.
    func revealChanges(_ selection: [NSRange]) -> [NSRange] {
        var now: Set<NSRange> = []
        for range in selection {
            for block in map.blocks(touching: range) {
                guard let line = Self.line(block) else { continue }
                if Self.touches(line, selection) { now.insert(line) }
            }
        }
        return Array(Set(now.symmetricDifference(revealed).compactMap { table(at: $0.location)?.range }))
    }

    /// Lays out the tables in `styled`, a copy of the storage from `offset` on, for a selection in its coordinates.
    func style(_ styled: NSMutableAttributedString, at offset: Int, selection: [NSRange]) {
        let whole = NSRange(location: offset, length: styled.length)
        revealed = revealed.filter { !NSLocationInRange($0.location, whole) }
        for head in map.blocks(in: whole) where head.kind == .tableHead {
            let table = Table(head: head, rows: rows(after: head))
            guard NSMaxRange(table.range) <= NSMaxRange(whole) else { continue }
            lay(table, in: styled, at: offset, selection: selection)
        }
    }

    private func lay(_ table: Table, in styled: NSMutableAttributedString, at offset: Int, selection: [NSRange]) {
        guard let headToken = table.head.spans.first(where: { $0.kind == .tableHead })?.shifted(by: table.head.range.location - offset) else { return }
        let store = ThemeStore.shared
        let text = styled.mutableString
        let header = headToken.content
        var delimiter = NSRange(location: NSMaxRange(header), length: NSMaxRange(headToken.range) - NSMaxRange(header))
        while delimiter.length > 0, [0x0A, 0x0D].contains(text.character(at: delimiter.location)) {
            delimiter = NSRange(location: delimiter.location + 1, length: delimiter.length - 1)
        }
        let alignments = Self.alignments(text.substring(with: delimiter))
        func cells(_ block: BlockMap.Block) -> [SyntaxSpan] {
            block.spans.filter { $0.kind == .tableCell }.map { $0.shifted(by: block.range.location - offset) }
        }
        var lines = [(range: header, token: headToken.range, cells: cells(table.head))]
        for row in table.rows {
            guard let token = row.spans.first(where: { $0.kind == .tableRow })?.shifted(by: row.range.location - offset) else { continue }
            lines.append((token.range, token.range, cells(row)))
        }
        let count = lines[0].cells.count
        guard count > 0 else { return }

        styled.enumerateAttribute(.font, in: header) { value, run, _ in
            styled.addAttribute(.font, value: store.font(value as! NSFont, adding: .bold), range: run)
        }
        let measured = lines.map { line in line.cells.prefix(count).map { styled.attributedSubstring(from: $0.content).size().width } }
        var widths = (0..<count).map { column in measured.map { $0.count > column ? $0[column] : 0 }.max() ?? 0 }
        let range = NSRange(location: table.head.range.location - offset, length: NSMaxRange(lines.last!.token) - (table.head.range.location - offset))
        if Self.touches(range, selection) {
            if let active, active.head == table.head.range.location, active.widths.count == count {
                widths = zip(widths, active.widths).map { max($0, $1) }
            }
            active = (table.head.range.location, widths)
        } else if active?.head == table.head.range.location {
            active = nil
        }
        widths = widths.map { $0.rounded(.up) }

        let gap = (MarkdownStyler.bodyFont.pointSize * 1.5).rounded()
        var starts: [CGFloat] = [0]
        for width in widths.dropLast() { starts.append(starts.last! + width + gap) }
        let boundaries = starts.dropFirst().map { $0 - gap / 2 }
        let rule = { (across: Bool) in
            BlockLine(.table(TableRule(columns: boundaries, width: starts.last! + widths.last!, across: across, color: store.color(.quoteRule))))
        }

        for (index, line) in lines.enumerated() {
            let shown = Self.touches(line.token, selection)
            var outside = IndexSet(integersIn: Range(line.range)!)
            for cell in line.cells.prefix(count) { outside.remove(integersIn: Range(cell.content)!) }
            if shown {
                revealed.insert(NSRange(location: line.token.location + offset, length: line.token.length))
                for part in outside.rangeView { styled.addAttribute(.foregroundColor, value: store.color(.syntax), range: NSRange(part)) }
                if index == 0 { styled.addAttribute(.foregroundColor, value: store.color(.syntax), range: delimiter) }
                continue
            }
            for part in outside.rangeView {
                styled.addAttributes([.font: MarkdownStyler.hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(part))
            }
            // Each kern moves the pen from where the text before it ends to where the next cell or rule wants it.
            var kerns: [Int: CGFloat] = [:]
            var pen: CGFloat = 0
            for (column, cell) in line.cells.prefix(count).enumerated() {
                let pipe = cell.range.location - 1
                if column > 0, pipe - 1 >= line.range.location {
                    kerns[pipe - 1, default: 0] += boundaries[column - 1] - pen
                    pen = boundaries[column - 1]
                }
                let width = measured[index][column]
                let inset: CGFloat = switch alignments.count > column ? alignments[column] : .left {
                case .left: 0
                case .center: ((widths[column] - width) / 2).rounded()
                case .right: widths[column] - width
                }
                let target = starts[column] + inset
                if cell.content.location - 1 >= line.range.location {
                    kerns[cell.content.location - 1, default: 0] += target - pen
                    pen = target + width
                } else {
                    pen = width
                }
            }
            for (at, kern) in kerns { styled.addAttribute(.kern, value: kern, range: NSRange(location: at, length: 1)) }
            styled.addAttribute(.dewlineBlock, value: rule(false), range: text.paragraphRange(for: NSRange(location: line.range.location, length: 0)))
            if index == 0, delimiter.length > 0 {
                styled.addAttributes([.font: MarkdownStyler.hiddenFont, .foregroundColor: NSColor.clear], range: delimiter)
                styled.addAttribute(.dewlineBlock, value: rule(true), range: text.paragraphRange(for: delimiter))
            }
        }
    }

    /// The alignment of each column in a delimiter row: `:--` left, `:-:` center, `--:` right.
    static func alignments(_ delimiter: String) -> [Alignment] {
        var row = Substring(delimiter.trimmingCharacters(in: .whitespacesAndNewlines))
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") { row = row.dropLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false).map { cell in
            let cell = cell.trimmingCharacters(in: .whitespaces)
            return cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .right) : .left
        }
    }

    /// A head's or row's token range, in the document.
    private static func line(_ block: BlockMap.Block) -> NSRange? {
        guard block.kind == .tableHead || block.kind == .tableRow,
            let token = block.spans.first(where: { $0.kind == .tableHead || $0.kind == .tableRow })
        else { return nil }
        return NSRange(location: token.range.location + block.range.location, length: token.range.length)
    }

    private func block(at location: Int) -> BlockMap.Block? {
        location >= 0 ? map.blocks(in: NSRange(location: location, length: 0)).first : nil
    }

    private func rows(after head: BlockMap.Block) -> [BlockMap.Block] {
        var rows: [BlockMap.Block] = []
        var end = NSMaxRange(head.range)
        while let next = block(at: end), next.range.location == end, next.kind == .tableRow {
            rows.append(next)
            end = NSMaxRange(next.range)
        }
        return rows
    }

    /// The table holding the line at `location`.
    private func table(at location: Int) -> Table? {
        guard var head = block(at: location), head.kind == .tableHead || head.kind == .tableRow else { return nil }
        while head.kind == .tableRow {
            guard let above = block(at: head.range.location - 1), NSMaxRange(above.range) == head.range.location,
                above.kind == .tableHead || above.kind == .tableRow
            else { return nil }
            head = above
        }
        return Table(head: head, rows: rows(after: head))
    }

    private static func touches(_ range: NSRange, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }
}
