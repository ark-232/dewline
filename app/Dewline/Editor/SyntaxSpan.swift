import Foundation

struct SyntaxSpan: Equatable {
    enum Kind: Equatable {
        case heading(level: Int), emphasis, strong, strikethrough, inlineCode, link
    }

    let kind: Kind
    let range: NSRange
    let content: NSRange

    var markers: [NSRange] {
        [
            NSRange(location: range.location, length: content.location - range.location),
            NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content)),
        ].filter { $0.length > 0 }
    }

    func shifted(by offset: Int) -> SyntaxSpan {
        SyntaxSpan(
            kind: kind,
            range: NSRange(location: range.location + offset, length: range.length),
            content: NSRange(location: content.location + offset, length: content.length)
        )
    }

    func contains(_ other: SyntaxSpan) -> Bool {
        other.range.location >= content.location && NSMaxRange(other.range) <= NSMaxRange(content)
    }
}

/// The spike's tokenizer, replaced by the Rust parser in M1.
enum SpikeTokenizer {
    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+(.*?)(?:[ \\t]+#+)?[ \\t]*$")
    private static let inline: [(SyntaxSpan.Kind, NSRegularExpression)] = [
        (.inlineCode, "(?<!`)(`+)(?!`)(.+?)(?<!`)\\1(?!`)"),
        (.link, "(?<!!)\\[()([^\\]]+)\\]\\([^)\\s]*\\)"),
        (.strong, "(\\*\\*)(?=\\S)(.+?)(?<=\\S)\\*\\*"),
        (.strikethrough, "(~~)(?=\\S)(.+?)(?<=\\S)~~"),
        (.emphasis, "(?<![*\\w])(\\*)(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![*\\w])"),
        (.emphasis, "(?<![_\\w])(_)(?=\\S)(.+?)(?<=\\S)_(?![_\\w])"),
    ].map { ($0, try! NSRegularExpression(pattern: $1)) }

    /// Spans in one line (a paragraph without its terminator), outer before inner.
    static func spans(in text: NSString, line: NSRange) -> [SyntaxSpan] {
        let source = text.substring(with: line)
        let whole = NSRange(location: 0, length: line.length)
        func span(_ kind: SyntaxSpan.Kind, _ match: NSTextCheckingResult) -> SyntaxSpan {
            let content = match.range(at: 2)
            return SyntaxSpan(
                kind: kind,
                range: NSRange(location: match.range.location + line.location, length: match.range.length),
                content: NSRange(location: content.location + line.location, length: content.length)
            )
        }
        var spans: [SyntaxSpan] = []
        if let match = heading.firstMatch(in: source, range: whole) {
            spans.append(span(.heading(level: match.range(at: 1).length), match))
        }
        for (kind, expression) in inline {
            for match in expression.matches(in: source, range: whole) {
                let candidate = span(kind, match)
                let fits = spans.allSatisfy { other in
                    NSIntersectionRange(candidate.range, other.range).length == 0
                        || (other.kind != .inlineCode && other.contains(candidate))
                        || candidate.contains(other)
                }
                if fits { spans.append(candidate) }
            }
        }
        return spans.sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
    }
}
