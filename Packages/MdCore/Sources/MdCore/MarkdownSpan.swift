internal import DewlineFFIBindings
import Foundation

/// A markdown construct in UTF-16 offsets. The characters in `range` but
/// outside `content` are the markers the editor hides.
public struct MarkdownSpan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case heading(level: Int), emphasis, strong, strikethrough, inlineCode, link, image, fencedCode
    }

    public let kind: Kind
    public let range: NSRange
    public let content: NSRange
}

/// Spans ordered by location, outer before inner.
public func markdownSpans(in text: String) -> [MarkdownSpan] {
    parseSpans(text: text).map { span in
        let kind: MarkdownSpan.Kind = switch span.kind {
        case .heading(let level): .heading(level: Int(level))
        case .emphasis: .emphasis
        case .strong: .strong
        case .strikethrough: .strikethrough
        case .inlineCode: .inlineCode
        case .link: .link
        case .image: .image
        case .fencedCode: .fencedCode
        }
        return MarkdownSpan(
            kind: kind,
            range: NSRange(location: Int(span.start), length: Int(span.end - span.start)),
            content: NSRange(location: Int(span.contentStart), length: Int(span.contentEnd - span.contentStart))
        )
    }
}
