import Foundation
import MdCore

/// A token of `core::md`'s parse.
struct SyntaxSpan: Hashable, Sendable {
    typealias Kind = MarkdownToken.Kind

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
}

/// The spike's tokenizer, which spelling still reads.
enum SpikeTokenizer {
    /// Code, a link's or image's destination, a link reference definition, an autolink or HTML tag, and a wikilink's
    /// target.
    private static let literal = try! NSRegularExpression(pattern: [
        "(?<!`)(`+)(?!`).+?(?<!`)\\1(?!`)",
        "\\]\\([^)\\s]*",
        "^ {0,3}\\[(?!\\^)[^\\]]+\\]:[ \\t]*\\S+",
        "</?[A-Za-z][^<>]*>",
        "\\[\\[[^\\]|]*",
    ].joined(separator: "|"))

    /// Ranges in one line that hold code or addresses rather than prose.
    static func literals(in text: NSString, line: NSRange) -> [NSRange] {
        literal.matches(in: text.substring(with: line), range: NSRange(location: 0, length: line.length)).map {
            NSRange(location: $0.range.location + line.location, length: $0.range.length)
        }
    }
}
