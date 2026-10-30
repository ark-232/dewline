import Foundation
import MdCore

/// The document as `core::md` parses it: its top-level blocks, top-level list items and table rows in order, each with
/// its tokens and rendered blocks. An edit shifts the map and parses the window around it on the main thread (record
/// 0006). A window that does not hold, one too long to parse, or an edit to a link or footnote definition leaves the
/// map provisional: blocks past the window keep their tokens until the whole text parses off the main thread, 300 ms
/// after the last edit.
@MainActor
final class BlockMap {
    struct Block: Equatable, Sendable {
        let kind: MarkdownBlock.Kind
        /// Whole lines: the last line's break is in, blank lines after it are out.
        var range: NSRange
        /// Outer before inner, in offsets from `range.location`.
        let spans: [SyntaxSpan]
        /// In offsets from `range.location`.
        let rendered: [RenderedBlock]
    }

    /// The text from the top that a new text's first parse takes on the main thread: its first screen and more.
    static let screen = 1 << 14
    /// `core::md`'s `WINDOW_LIMIT` in UTF-8 bytes, which a window's UTF-16 length cannot pass without its bytes passing.
    private static let windowLimit = 4096

    /// Receives the ranges whose blocks a whole parse changed, once it replaces the map.
    var merged: ([NSRange]) -> Void = { _ in }
    /// Whether blocks may differ from a whole parse's until the next one lands.
    private(set) var isProvisional = false
    /// Where the text the map has blocks for ends: the text's end, unless a new text's first whole parse still runs.
    var parsed: Int { unparsed ?? length }

    private let parser = MarkdownParser()
    private let queue = DispatchQueue(label: "dev.arkwerx.dewline.markdown", qos: .userInitiated)
    private var text: NSString = ""
    /// Counts edits, so a whole parse of an older text is never installed.
    private var version = 0
    private var unparsed: Int?
    private var idle: Timer?
    // A gap buffer, so an edit near the last one moves few blocks.
    private var front: [Block] = []
    /// The blocks after the gap, last first, each at its offset from the end of the text.
    private var back: [Block] = []
    private var length = 0

    private var count: Int { front.count + back.count }

    private func range(_ index: Int) -> NSRange {
        if index < front.count { return front[index].range }
        let range = back[back.count - 1 - (index - front.count)].range
        return NSRange(location: length - range.location, length: range.length)
    }

    private func block(_ index: Int) -> Block {
        if index < front.count { return front[index] }
        var block = back[back.count - 1 - (index - front.count)]
        block.range.location = length - block.range.location
        return block
    }

    private func moveGap(to index: Int) {
        while front.count > index {
            var block = front.removeLast()
            block.range.location = length - block.range.location
            back.append(block)
        }
        while front.count < index {
            var block = back.removeLast()
            block.range.location = length - block.range.location
            front.append(block)
        }
    }

    /// The index of the first block that ends after `offset`.
    private func index(endingAfter offset: Int) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(range(middle)) > offset { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// The blocks that end after `after` and start before `before`.
    private func blocks(after: Int, before: Int) -> [Block] {
        var index = index(endingAfter: after)
        var found: [Block] = []
        while index < count, range(index).location < before {
            found.append(block(index))
            index += 1
        }
        return found
    }

    /// The blocks with characters in `range`, or for an empty range the block holding its location.
    func blocks(in range: NSRange) -> [Block] {
        blocks(after: range.location, before: max(NSMaxRange(range), range.location + 1))
    }

    /// The blocks that `range` meets or touches.
    func blocks(touching range: NSRange) -> [Block] {
        blocks(after: range.location - 1, before: NSMaxRange(range) + 1)
    }

    /// `range` and the blocks it meets.
    func covering(_ range: NSRange) -> NSRange {
        blocks(in: range).reduce(range) { NSUnionRange($0, $1.range) }
    }

    /// The rendered blocks with characters in `range`.
    func renderedBlocks(in range: NSRange) -> [RenderedBlock] {
        blocks(in: range).flatMap { block in block.rendered.map { $0.shifted(by: block.range.location) } }
            .filter { NSIntersectionRange($0.range, range).length > 0 }
    }

    /// The rendered blocks in the blocks that `range` meets or touches.
    func renderedBlocks(touching range: NSRange) -> [RenderedBlock] {
        blocks(touching: range).flatMap { block in block.rendered.map { $0.shifted(by: block.range.location) } }
    }

    /// Whether `range` meets fenced or indented code, front matter or a math block.
    func isCode(_ range: NSRange) -> Bool {
        blocks(in: range).contains { block in
            let local = NSRange(location: range.location - block.range.location, length: range.length)
            return block.kind == .code || block.kind == .frontMatter
                || block.spans.contains { $0.kind == .fencedCode && NSIntersectionRange($0.content, local).length > 0 }
                || block.rendered.contains { $0.kind == .math && NSIntersectionRange($0.range, local).length > 0 }
        }
    }

    /// Shifts the map past an edit that left `edited` in `text` where `edited.length - delta` characters were, and
    /// parses the window around it. Returns the range of `text` whose blocks the edit may have changed.
    func textDidChange(_ text: NSString, edited: NSRange, delta: Int) -> NSRange {
        self.text = text
        version += 1
        if edited.location == 0, edited.length == text.length {
            return open()
        }
        let oldEnd = NSMaxRange(edited) - delta
        // The edit's lines, with the line after a line break it ends with.
        let core = Self.lines(text, NSRange(location: edited.location, length: min(edited.length + 1, text.length - edited.location)))
        let first = index(endingAfter: core.location)
        var last = first
        while last < count, range(last).location < NSMaxRange(core) - delta { last += 1 }
        if let unparsed {
            guard NSMaxRange(core) - delta <= unparsed else {
                // Past the first screen before the first whole parse landed: everything parses now.
                (front, back, length, self.unparsed, isProvisional) = ([], [], text.length, nil, true)
                reparseNow(gap: edited.location)
                if isProvisional { reparseSoon() }
                return covering(core)
            }
            self.unparsed = unparsed + delta
        }
        moveGap(to: last)
        length = text.length
        var start = core.location
        var end = NSMaxRange(core)
        if first < last {
            start = min(start, front[first].range.location)
            let blockEnd = NSMaxRange(front[last - 1].range)
            end = max(end, blockEnd < edited.location ? blockEnd : max(blockEnd + delta, NSMaxRange(edited)))
        }
        let touched = NSRange(location: start, length: end - start)

        // The window, as `window_of` in core::md cuts it: for an edit in a body row and off its line break, the row with
        // the table's head; otherwise the blocks the edit meets, the rows after a table's head or row among them, and
        // the block above when no blank line separates them or the window starts with a blank or a line break, with a
        // quote, item or footnote right above that one.
        var heading: NSRange?
        var row = false
        var w0 = first
        var rows = 0
        let head = { (index: Int) in (0..<index).last { self.front[$0].kind == .tableHead }.map { self.front[$0].range } }
        // A character of the old text, where the edit left it.
        func old(_ offset: Int) -> unichar? {
            offset < edited.location ? text.character(at: offset) : offset >= oldEnd ? text.character(at: offset + delta) : nil
        }
        // Where the edited row's line break starts, when the edit left enough of the row to tell.
        func lineBreak(_ row: NSRange) -> Int? {
            let end = NSMaxRange(row)
            guard let last = old(end - 1) else { return nil }
            guard last == 0x0A || last == 0x0D else { return end }
            guard last == 0x0A else { return end - 1 }
            return old(end - 2).map { $0 == 0x0D ? end - 2 : end - 1 }
        }
        if last - first == 1, front[first].kind == .tableRow, let found = head(first), let at = lineBreak(front[first].range), oldEnd <= at {
            heading = found
            row = true
        } else {
            if front[first..<last].contains(where: { $0.kind == .tableHead || $0.kind == .tableRow }) {
                while last + rows < count, block(last + rows).kind == .tableRow { rows += 1 }
                if rows > 0 { end = NSMaxRange(range(last + rows - 1)) }
            }
            if first > 0 {
                let above = front[first - 1]
                // A fence or HTML block left open at the end of the text takes in whatever follows it.
                let open = last == count && (above.kind == .html || above.spans.contains { $0.kind == .fencedCode && NSMaxRange($0.content) == NSMaxRange($0.range) })
                if open || NSMaxRange(above.range) == start || (start < text.length && [0x20, 0x09, 0x0A, 0x0D].contains(text.character(at: start))) {
                    w0 = first - 1
                    if first > 1, NSMaxRange(front[first - 2].range) == above.range.location,
                        [.quote, .callout, .item, .footnoteDefinition].contains(front[first - 2].kind)
                    {
                        w0 = first - 2
                    }
                    start = front[w0].range.location
                }
            }
            if w0 < last, front[w0].kind == .tableRow { heading = head(w0) }
        }
        let main = NSRange(location: start, length: end - start)
        let next = Self.lookahead(text, from: end)
        var made: [Block]?
        var holds = false
        if (heading?.length ?? 0) + main.length + next.length <= Self.windowLimit {
            let window = (heading.map(text.substring(with:)) ?? "") + text.substring(with: main)
            let atStart = (heading ?? main).location == 0
            if let parse = try? parser.parse(window: window, next: text.substring(with: next), atStart: atStart, row: row) {
                made = Self.blocks(of: parse, from: heading?.length ?? 0, at: start, in: text)
                holds = parse.holds
            }
        }
        // A window cannot tell a label's first definition from a later one, and a table's head holds its definitions
        // without their tokens, so an edit that may change a label waits for the whole parse.
        let defines = { (block: Block) in block.spans.contains { $0.kind == .definition || $0.kind == .footnoteDefinition } }
        let labels = front[w0..<last].contains(where: defines) || front[first..<last].contains { $0.kind == .tableHead }
        defer { if isProvisional { reparseSoon() } }
        if let made {
            front.removeSubrange(w0...)
            back.removeLast(rows)
            front.append(contentsOf: made)
            if !holds || labels || made.contains(where: defines) { isProvisional = true }
            return main
        }
        // Too long to parse, or the parser panicked: the edited blocks join, keeping the tokens the edit missed.
        isProvisional = true
        guard first < last else { return touched }
        var spans: [SyntaxSpan] = []
        var rendered: [RenderedBlock] = []
        for block in front[first..<last] {
            let at = block.range.location
            for span in block.spans {
                if at + NSMaxRange(span.range) <= edited.location {
                    spans.append(span.shifted(by: at - touched.location))
                } else if at + span.range.location >= oldEnd {
                    spans.append(span.shifted(by: at + delta - touched.location))
                }
            }
            for picture in block.rendered {
                if at + NSMaxRange(picture.range) <= edited.location {
                    rendered.append(picture.shifted(by: at - touched.location))
                } else if at + picture.range.location >= oldEnd {
                    rendered.append(picture.shifted(by: at + delta - touched.location))
                }
            }
        }
        let joined = Block(kind: front[first].kind, range: touched, spans: spans, rendered: rendered)
        front.removeSubrange(first...)
        front.append(joined)
        return touched
    }

    /// A new text: its first screen parses now, the rest off the main thread.
    private func open() -> NSRange {
        idle?.invalidate()
        let prefix = text.length <= Self.screen ? text.length : Self.lineEnd(text, Self.screen)
        let parse = try? parser.parse(text.substring(to: prefix))
        (front, back, length) = (parse.map { Self.blocks(of: $0, from: 0, at: 0, in: text) } ?? [], [], text.length)
        isProvisional = parse == nil
        unparsed = prefix < text.length ? prefix : nil
        if unparsed != nil { reparse() } else if isProvisional { reparseSoon() }
        return NSRange(location: 0, length: text.length)
    }

    /// Parses the whole text off the main thread 300 ms from now, unless an edit comes first.
    private func reparseSoon() {
        idle?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reparse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idle = timer
    }

    /// Parses the whole text off the main thread, and installs the result if no edit came meanwhile. The result comes
    /// through the main run loop, which unlike the main queue also runs inside a main-queue job.
    private func reparse() {
        idle?.invalidate()
        // A copy: the storage's string changes under a parse that reads it.
        let (version, text, old, gap) = (version, text.substring(from: 0), blocks(after: -1, before: .max), front.last.map { NSMaxRange($0.range) } ?? 0)
        queue.async { [parser] in
            guard let parse = try? parser.parse(text) else { return }
            let result = Self.result(of: parse, in: text as NSString, replacing: old, gap: gap)
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { self.install(result, version: version) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// Parses the whole text now, on the main thread.
    func reparseNow() {
        reparseNow(gap: front.last.map { NSMaxRange($0.range) } ?? 0)
    }

    private func reparseNow(gap: Int) {
        guard let parse = try? parser.parse(text as String) else { return }
        install(Self.result(of: parse, in: text, replacing: blocks(after: -1, before: .max), gap: gap), version: version)
    }

    private func install(_ result: (front: [Block], back: [Block], changed: [NSRange]), version: Int) {
        guard version == self.version else {
            // The first whole parse goes on until one lands; a provisional map waits for the edits to pause.
            if unparsed != nil { reparse() }
            return
        }
        idle?.invalidate()
        (front, back) = (result.front, result.back)
        unparsed = nil
        isProvisional = false
        merged(result.changed)
    }

    /// A whole parse's blocks split at `gap`, and the ranges where they differ from `old`.
    private nonisolated static func result(
        of parse: MarkdownParse, in text: NSString, replacing old: [Block], gap: Int
    ) -> (front: [Block], back: [Block], changed: [NSRange]) {
        let new = blocks(of: parse, from: 0, at: 0, in: text)
        var changed: [NSRange] = []
        // Whether the block before the one in hand changed, so that a run of changed blocks is one range.
        var run = false
        func add(_ range: NSRange) {
            if run, let last = changed.popLast() { changed.append(NSUnionRange(last, range)) } else { changed.append(range) }
            run = true
        }
        var (i, j) = (0, 0)
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                (i, j, run) = (i + 1, j + 1, false)
            } else if j < new.count, i == old.count || new[j].range.location <= old[i].range.location {
                add(new[j].range)
                j += 1
            } else {
                add(old[i].range)
                i += 1
            }
        }
        let split = new.firstIndex { $0.range.location >= gap } ?? new.count
        let back = new[split...].reversed().map { block in
            var block = block
            block.range.location = text.length - block.range.location
            return block
        }
        return (Array(new[..<split]), back, changed)
    }

    /// The blocks of `parse` from `skip` on, at `offset` in the document, with their tokens and rendered blocks.
    private nonisolated static func blocks(of parse: MarkdownParse, from skip: Int, at offset: Int, in text: NSString) -> [Block] {
        let tokens = parse.tokens
        var next = tokens.startIndex
        var found: [Block] = []
        for (index, block) in parse.blocks.enumerated() {
            let end = NSMaxRange(block.range)
            var spans: [SyntaxSpan] = []
            while next < tokens.endIndex {
                let token = tokens[next]
                // A token lies inside its block; one empty at the end of the text is in the last block.
                guard token.range.location < end || (index == parse.blocks.count - 1 && token.range.location == end) else { break }
                let local = block.range.location
                spans.append(SyntaxSpan(
                    kind: token.kind, range: NSRange(location: token.range.location - local, length: token.range.length),
                    content: NSRange(location: token.content.location - local, length: token.content.length)
                ))
                next += 1
            }
            guard block.range.location >= skip else { continue }
            let range = NSRange(location: block.range.location - skip + offset, length: block.range.length)
            // Mermaid, `$$` math and lone images, found by the scanner until its rules move into core::md.
            let rendered = block.kind == .frontMatter ? [] : BlockScanner.scan(text.substring(with: range) as NSString).blocks
            found.append(Block(kind: block.kind, range: range, spans: spans, rendered: rendered))
        }
        return found
    }

    /// The whole lines holding `range`, each with its line break, as `core::md` breaks lines: at `\n`, `\r` or `\r\n`.
    private nonisolated static func lines(_ text: NSString, _ range: NSRange) -> NSRange {
        var start = range.location
        while start > 0, ![0x0A, 0x0D].contains(text.character(at: start - 1)) { start -= 1 }
        let end = lineEnd(text, range.length > 0 ? NSMaxRange(range) - 1 : range.location)
        return NSRange(location: start, length: end - start)
    }

    /// The end of the line holding `offset`, past its line break.
    private nonisolated static func lineEnd(_ text: NSString, _ offset: Int) -> Int {
        var end = offset
        while end < text.length {
            let character = text.character(at: end)
            end += 1
            if character == 0x0A { break }
            if character == 0x0D {
                if end < text.length, text.character(at: end) == 0x0A { end += 1 }
                break
            }
        }
        return end
    }

    /// A window's `next`: the lines after `end` through the first one that is not blank and the line after it, or the
    /// blank lines to the end of the text.
    private nonisolated static func lookahead(_ text: NSString, from end: Int) -> NSRange {
        var at = end
        func blank(_ line: Int) -> Bool {
            var at = line
            while at < text.length, [0x20, 0x09].contains(text.character(at: at)) { at += 1 }
            return at == text.length || [0x0A, 0x0D].contains(text.character(at: at))
        }
        while at < text.length, blank(at) { at = lineEnd(text, at) }
        if at < text.length { at = lineEnd(text, lineEnd(text, at)) }
        return NSRange(location: end, length: at - end)
    }
}
