import Foundation

/// Line and word arithmetic over the text Vim edits, in UTF-16 offsets. A text that ends in a newline has no empty
/// line after it, as in Vim.
struct VimText {
    let string: NSString

    var length: Int { string.length }

    func char(_ p: Int) -> unichar {
        string.character(at: p)
    }

    func next(_ p: Int) -> Int {
        p < length ? NSMaxRange(string.rangeOfComposedCharacterSequence(at: p)) : length
    }

    func previous(_ p: Int) -> Int {
        p > 0 ? string.rangeOfComposedCharacterSequence(at: p - 1).location : 0
    }

    func lineStart(_ p: Int) -> Int {
        var start = 0
        string.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: min(p, length), length: 0))
        return start
    }

    func lineEnd(_ p: Int) -> Int {
        var end = 0
        string.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: min(p, length), length: 0))
        return end
    }

    /// Past the line's newline.
    func fullLineEnd(_ p: Int) -> Int {
        var end = 0
        string.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: min(p, length), length: 0))
        return end
    }

    func nextLine(_ p: Int) -> Int? {
        let end = fullLineEnd(p)
        return end < length ? end : nil
    }

    func previousLine(_ p: Int) -> Int? {
        let start = lineStart(p)
        return start > 0 ? lineStart(start - 1) : nil
    }

    /// The start of line `number`, counting from 1; past the last line, the last line.
    func line(_ number: Int) -> Int {
        var line = 0
        for _ in 1..<max(number, 1) {
            guard let next = nextLine(line) else { break }
            line = next
        }
        return line
    }

    /// The whole lines from the one holding `a` through the one holding `b`, newlines included.
    func lines(_ a: Int, _ b: Int) -> NSRange {
        let start = lineStart(a)
        return NSRange(location: start, length: fullLineEnd(b) - start)
    }

    func lastCharacter(_ p: Int) -> Int {
        let start = lineStart(p)
        let end = lineEnd(p)
        return end > start ? previous(end) : start
    }

    func isBlank(_ p: Int) -> Bool {
        let c = char(p)
        return c == 32 || c == 9
    }

    /// The line's first non-blank character, or its end.
    func nonBlank(_ p: Int) -> Int {
        var q = lineStart(p)
        let end = lineEnd(p)
        while q < end, isBlank(q) { q += 1 }
        return q
    }

    /// Where the normal-mode cursor sits for `p`: on a character, never on a newline unless the line is empty.
    func normal(_ p: Int) -> Int {
        var p = min(max(p, 0), length)
        if p == length, p > 0, char(p - 1) == 10 { p -= 1 }
        if p < length { p = string.rangeOfComposedCharacterSequence(at: p).location }
        let start = lineStart(p)
        let end = lineEnd(p)
        return p < end ? p : end > start ? previous(end) : start
    }

    /// 0 for blanks and newlines, 1 for word characters, 2 for punctuation.
    func kind(_ p: Int) -> Int {
        let c = char(p)
        if c == 32 || c == 9 || c == 10 || c == 13 { return 0 }
        if c == 95 || (0xD800..<0xE000).contains(c) { return 1 }
        guard let scalar = Unicode.Scalar(c) else { return 1 }
        if CharacterSet.whitespaces.contains(scalar) { return 0 }
        return CharacterSet.alphanumerics.contains(scalar) ? 1 : 2
    }

    /// `w`: the next word's start, an empty line, or the end of the text.
    func wordForward(_ p: Int) -> Int {
        guard p < length else { return length }
        var p = p
        let k = kind(p)
        if k != 0 { while p < length, kind(p) == k { p += 1 } }
        while p < length, kind(p) == 0 {
            if char(p) == 10 {
                p += 1
                if p < length, char(p) == 10 { return p }
            } else {
                p += 1
            }
        }
        return p
    }

    /// `b`: the start of this word or the one before, or an empty line.
    func wordBackward(_ p: Int) -> Int {
        guard p > 0 else { return 0 }
        var p = p - 1
        while p > 0, kind(p) == 0 {
            if char(p) == 10, char(p - 1) == 10 { return p }
            p -= 1
        }
        let k = kind(p)
        guard k != 0 else { return p }
        while p > 0, kind(p - 1) == k { p -= 1 }
        return p
    }

    /// `e`: the end of the next word.
    func wordEnd(_ p: Int) -> Int {
        var p = p + 1
        while p < length, kind(p) == 0 { p += 1 }
        guard p < length else { return max(length - 1, 0) }
        let k = kind(p)
        while p + 1 < length, kind(p + 1) == k { p += 1 }
        return p
    }

    /// The end of the word `p` is in, for `cw`.
    func wordEndInside(_ p: Int) -> Int {
        let k = kind(p)
        var p = p
        while p + 1 < length, kind(p + 1) == k { p += 1 }
        return p
    }

    func vertical(_ at: Int, _ lines: Int) -> Int? {
        var line = lineStart(at)
        let column = at - line
        var moved = 0
        while moved < abs(lines), let next = lines > 0 ? nextLine(line) : previousLine(line) {
            line = next
            moved += 1
        }
        guard moved > 0 else { return nil }
        return normal(min(line + column, lineEnd(line)))
    }

    /// `%`: the bracket matching the first one at or after `at` on its line.
    func match(_ at: Int) -> Int? {
        let opens: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
        let closes: [unichar: unichar] = [41: 40, 93: 91, 125: 123]
        let end = lineEnd(at)
        var p = at
        while p < end, opens[char(p)] == nil, closes[char(p)] == nil { p += 1 }
        guard p < end else { return nil }
        let c = char(p)
        let other = opens[c] ?? closes[c]!
        let step = opens[c] != nil ? 1 : -1
        var depth = 0
        while p >= 0, p < length {
            if char(p) == c { depth += 1 } else if char(p) == other { depth -= 1 }
            if depth == 0 { return p }
            p += step
        }
        return nil
    }

    func find(_ pattern: String, forward: Bool, from at: Int) -> Int? {
        let whole = NSRange(location: 0, length: length)
        var found: NSRange
        if forward {
            let start = min(at + 1, length)
            found = string.range(of: pattern, options: .literal, range: NSRange(location: start, length: length - start))
            if found.location == NSNotFound { found = string.range(of: pattern, options: .literal, range: whole) }
        } else {
            found = string.range(of: pattern, options: [.literal, .backwards], range: NSRange(location: 0, length: at))
            if found.location == NSNotFound { found = string.range(of: pattern, options: [.literal, .backwards], range: whole) }
        }
        return found.location == NSNotFound ? nil : found.location
    }

    /// `iw` and `aw`: the run of one kind of character holding `at`, with blanks after it (or before) for `aw`.
    func word(_ at: Int, around: Bool) -> NSRange? {
        let start = lineStart(at)
        let end = lineEnd(at)
        guard at < end else { return nil }
        let k = kind(at)
        var low = at
        var high = at + 1
        while low > start, kind(low - 1) == k { low -= 1 }
        while high < end, kind(high) == k { high += 1 }
        if around {
            if k == 0 {
                if high < end {
                    let next = kind(high)
                    while high < end, kind(high) == next { high += 1 }
                }
            } else if high < end, kind(high) == 0 {
                while high < end, kind(high) == 0 { high += 1 }
            } else {
                while low > start, kind(low - 1) == 0 { low -= 1 }
            }
        }
        return NSRange(location: low, length: high - low)
    }

    /// `i"` and `a"`: the quoted string on the line around `at`, or the next one.
    func quote(_ at: Int, around: Bool) -> NSRange? {
        let start = lineStart(at)
        let end = lineEnd(at)
        let quotes = (start..<end).filter { char($0) == 34 }
        let pairs = stride(from: 0, to: quotes.count - 1, by: 2)
        guard let i = pairs.first(where: { quotes[$0] <= at && at <= quotes[$0 + 1] }) ?? pairs.first(where: { quotes[$0] > at }) else {
            return nil
        }
        let open = quotes[i]
        let close = quotes[i + 1]
        guard around else { return NSRange(location: open + 1, length: close - open - 1) }
        var low = open
        var high = close + 1
        while high < end, isBlank(high) { high += 1 }
        if high == close + 1 {
            while low > start, isBlank(low - 1) { low -= 1 }
        }
        return NSRange(location: low, length: high - low)
    }

    /// The parentheses enclosing `at`, or the pair that starts there.
    func parentheses(_ at: Int) -> (open: Int, close: Int)? {
        guard at < length else { return nil }
        var open: Int?
        if char(at) == 40 {
            open = at
        } else {
            var depth = 0
            var p = at - 1
            while p >= 0 {
                let c = char(p)
                if c == 41 {
                    depth += 1
                } else if c == 40 {
                    if depth == 0 {
                        open = p
                        break
                    }
                    depth -= 1
                }
                p -= 1
            }
        }
        guard let open else { return nil }
        var depth = 0
        var p = open + 1
        while p < length {
            let c = char(p)
            if c == 40 {
                depth += 1
            } else if c == 41 {
                if depth == 0 { return (open, p) }
                depth -= 1
            }
            p += 1
        }
        return nil
    }

    /// `ip` and `ap`: the lines of the paragraph (or the run of blank lines) holding `at`, with what follows for `ap`.
    func paragraph(_ at: Int, around: Bool) -> NSRange {
        func blank(_ line: Int) -> Bool { nonBlank(line) == lineEnd(line) }
        var first = lineStart(at)
        var last = first
        let empty = blank(first)
        while let previous = previousLine(first), blank(previous) == empty { first = previous }
        while let next = nextLine(last), blank(next) == empty { last = next }
        if around {
            if let next = nextLine(last) {
                let kind = blank(next)
                last = next
                while let following = nextLine(last), blank(following) == kind { last = following }
            } else if !empty {
                while let previous = previousLine(first), blank(previous) { first = previous }
            }
        }
        return lines(first, last)
    }
}
