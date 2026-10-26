import Foundation

/// A block drawn as a picture while the selection is outside it: a fenced `mermaid` diagram, a `$$` formula, or a
/// paragraph that is only an image. Like a span, the characters in `range` but outside `content` are its markers.
struct RenderedBlock: Hashable {
    enum Kind: Hashable {
        case mermaid, math, image
    }

    let kind: Kind
    /// Whole lines, without the last line's terminator.
    let range: NSRange
    let content: NSRange
    /// The diagram, the TeX, or the image's path.
    let source: String
    /// What VoiceOver reads for the picture: the diagram's first line, the TeX, or the image's alt text.
    let label: String

    func shifted(by offset: Int) -> RenderedBlock {
        RenderedBlock(
            kind: kind, range: NSRange(location: range.location + offset, length: range.length),
            content: NSRange(location: content.location + offset, length: content.length), source: source, label: label
        )
    }
}

/// The document's rendered blocks, kept current through edits. An edit away from every fence, formula and image
/// shifts the index; one that could make or break a block rescans the document.
struct BlockIndex {
    private(set) var blocks: [RenderedBlock] = []
    /// Every fence line, rendered or not and closed or not, since an edit to any of them can re-pair the rest.
    private var fences: [NSRange] = []

    /// Updates the index for `edited` (in the new text), which replaced `edited.length - delta` characters, and
    /// returns the ranges in the new text whose blocks appeared, changed or went away.
    mutating func update(_ text: NSString, edited: NSRange, delta: Int) -> [NSRange] {
        let oldEnd = NSMaxRange(edited) - delta
        var dirty = false
        func moved(_ range: NSRange) -> NSRange {
            if NSMaxRange(range) < edited.location { return range }
            if range.location > oldEnd { return NSRange(location: range.location + delta, length: range.length) }
            dirty = true
            let start = min(range.location, edited.location)
            return NSRange(location: start, length: max(NSMaxRange(range) + delta, NSMaxRange(edited)) - start)
        }
        let old = blocks.map { block in
            (moved: moved(block.range), now: block.range.location > oldEnd ? block.shifted(by: delta) : block)
        }
        let shiftedFences = fences.map(moved)
        // An image is a block only while the paragraphs around it are blank.
        let paragraphs = text.paragraphRange(for: edited)
        var around = NSUnionRange(paragraphs, text.paragraphRange(for: NSRange(location: max(paragraphs.location - 1, 0), length: 0)))
        around = NSUnionRange(around, text.paragraphRange(for: NSRange(location: min(NSMaxRange(paragraphs), text.length), length: 0)))
        let image = old.contains { $0.now.kind == .image && NSIntersectionRange($0.moved, around).length > 0 }
        let marked = ["```", "~~~", "$$"].contains { text.range(of: $0, range: paragraphs).location != NSNotFound }
            || text.range(of: "![", range: around).location != NSNotFound
        guard dirty || image || marked else {
            blocks = old.map(\.now)
            fences = shiftedFences
            return []
        }
        let kept = Set(old.map(\.now))
        (blocks, fences) = BlockScanner.scan(text)
        let now = Set(blocks)
        return Array(Set(blocks.filter { !kept.contains($0) }.map(\.range) + old.filter { !now.contains($0.now) }.map(\.moved)))
    }
}

/// Finds rendered blocks line by line. Fences pair as in CommonMark, and an unclosed fence makes the rest of the
/// document code.
enum BlockScanner {
    private static let image = try! NSRegularExpression(pattern: "^ {0,3}!\\[([^\\]]*)\\]\\(([^)\\s:/][^)\\s:]*)\\)[ \\t]*$")

    static func scan(_ text: NSString) -> (blocks: [RenderedBlock], fences: [NSRange]) {
        var lines: [NSRange] = []
        var location = 0
        while location < text.length {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append(NSRange(location: location, length: contentsEnd - location))
            location = end
        }
        // The first character after at most three spaces.
        func start(_ line: NSRange) -> Int? {
            var at = line.location
            while at < NSMaxRange(line), at - line.location < 3, text.character(at: at) == 0x20 { at += 1 }
            return at < NSMaxRange(line) ? at : nil
        }
        func fence(_ line: NSRange) -> (mark: unichar, count: Int, info: String)? {
            guard let first = start(line), [0x60, 0x7E].contains(text.character(at: first)) else { return nil }
            let mark = text.character(at: first)
            var end = first
            while end < NSMaxRange(line), text.character(at: end) == mark { end += 1 }
            let info = text.substring(with: NSRange(location: end, length: NSMaxRange(line) - end)).trimmingCharacters(in: .whitespaces)
            return end - first >= 3 && !(mark == 0x60 && info.contains("`")) ? (mark, end - first, info) : nil
        }
        func closingDollars(_ line: NSRange, from: Int) -> Int? {
            var end = NSMaxRange(line)
            while end > from, [0x20, 0x09].contains(text.character(at: end - 1)) { end -= 1 }
            return end - from >= 2 && text.character(at: end - 1) == 0x24 && text.character(at: end - 2) == 0x24 ? end - 2 : nil
        }
        func blank(_ index: Int) -> Bool {
            !lines.indices.contains(index) || text.substring(with: lines[index]).allSatisfy(\.isWhitespace)
        }

        var blocks: [RenderedBlock] = []
        var fences: [NSRange] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let open = fence(line) {
                var close = index + 1
                while close < lines.count, !(fence(lines[close]).map { $0.mark == open.mark && $0.count >= open.count && $0.info.isEmpty } ?? false) {
                    close += 1
                }
                fences.append(line)
                guard close < lines.count else { break }
                fences.append(lines[close])
                let range = NSUnionRange(line, lines[close])
                if open.info.split(separator: " ").first == "mermaid" {
                    let content = close > index + 1 ? NSUnionRange(lines[index + 1], lines[close - 1]) : NSRange(location: lines[close].location, length: 0)
                    let source = text.substring(with: content)
                    let label = source.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    blocks.append(RenderedBlock(kind: .mermaid, range: range, content: content, source: source, label: label))
                }
                index = close + 1
                continue
            }
            if let first = start(line), first + 1 < NSMaxRange(line), text.character(at: first) == 0x24, text.character(at: first + 1) == 0x24 {
                var close = index
                var dollars = closingDollars(line, from: first + 2)
                // `$$x$$ and more` is math inside a paragraph.
                let inline = dollars == nil
                    && text.range(of: "$$", range: NSRange(location: first + 2, length: NSMaxRange(line) - first - 2)).location != NSNotFound
                while dollars == nil, !inline, close + 1 < lines.count {
                    close += 1
                    dollars = closingDollars(lines[close], from: lines[close].location)
                }
                if let dollars {
                    let content = NSRange(location: first + 2, length: dollars - first - 2)
                    let tex = text.substring(with: content).trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append(RenderedBlock(kind: .math, range: NSUnionRange(line, lines[close]), content: content, source: tex, label: tex))
                    index = close + 1
                    continue
                }
            }
            if let first = start(line), text.character(at: first) == 0x21, blank(index - 1), blank(index + 1) {
                let string = text.substring(with: line)
                if let match = image.firstMatch(in: string, range: NSRange(location: 0, length: line.length)) {
                    let alt = (string as NSString).substring(with: match.range(at: 1))
                    let path = (string as NSString).substring(with: match.range(at: 2))
                    blocks.append(RenderedBlock(kind: .image, range: line, content: line, source: path, label: alt))
                }
            }
            index += 1
        }
        return (blocks, fences)
    }
}
