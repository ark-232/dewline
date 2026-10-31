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
