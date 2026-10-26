internal import DewlineFFIBindings
import Foundation

/// One document's markdown parser. It keeps the link and footnote labels of the document's last whole parse, which
/// its windows resolve references against. Each parse throws when the parser panics.
public final class MarkdownParser: Sendable {
    private let markdown = DewlineFFIBindings.Markdown()

    public init() {}

    /// The whole document. Its labels replace the ones windows use.
    public func parse(_ text: String) throws -> MarkdownParse {
        MarkdownParse(try markdown.parse(text: utf8(text)))
    }

    /// A window cut from the document (see `core::md::Window`), or nil when `text` and `next` are over 4 KB of UTF-8.
    public func parse(window text: String, next: String, atStart: Bool, row: Bool) throws -> MarkdownParse? {
        try markdown.parseWindow(text: utf8(text), next: utf8(next), atStart: atStart, row: row).map(MarkdownParse.init)
    }

    /// Panics in Rust. Only the test that a panic comes back as an error calls it.
    public func panicForTest() throws {
        _ = try markdown.panicForTest()
    }

    /// Text from a text storage is UTF-16, which UniFFI would read into UTF-8 a character at a time.
    private func utf8(_ text: String) -> String {
        var text = text
        text.makeContiguousUTF8()
        return text
    }
}

/// A parse's blocks and tokens in UTF-16 offsets, read from the parser's records as they are used.
public struct MarkdownParse: Sendable {
    private let words: [UInt32]

    init(_ records: Data) {
        words = Array(unsafeUninitializedCapacity: records.count / 4) { buffer, count in
            count = records.copyBytes(to: buffer) / 4
        }
    }

    /// Whether the rest of the document still parses as it did; true for a whole document.
    public var holds: Bool { word(0) != 0 }

    /// In order and apart, each whole lines.
    public var blocks: Blocks { Blocks(parse: self) }

    /// Ordered by location, outer before inner.
    public var tokens: Tokens { Tokens(parse: self) }

    fileprivate func word(_ index: Int) -> UInt32 {
        UInt32(littleEndian: words[index])
    }

    public struct Blocks: RandomAccessCollection, Sendable {
        fileprivate let parse: MarkdownParse

        public var startIndex: Int { 0 }
        public var endIndex: Int { Int(parse.word(1)) }

        public subscript(index: Int) -> MarkdownBlock {
            precondition((0..<endIndex).contains(index), "block \(index) of \(endIndex)")
            let at = 3 + 3 * index
            let start = Int(parse.word(at + 1))
            return MarkdownBlock(
                kind: MarkdownBlock.Kind(parse.word(at)),
                range: NSRange(location: start, length: Int(parse.word(at + 2)) - start)
            )
        }
    }

    public struct Tokens: RandomAccessCollection, Sendable {
        fileprivate let parse: MarkdownParse

        public var startIndex: Int { 0 }
        public var endIndex: Int { Int(parse.word(2)) }

        public subscript(index: Int) -> MarkdownToken {
            precondition((0..<endIndex).contains(index), "token \(index) of \(endIndex)")
            let at = 3 + 3 * Int(parse.word(1)) + 5 * index
            let (start, contentStart) = (Int(parse.word(at + 1)), Int(parse.word(at + 2)))
            return MarkdownToken(
                kind: MarkdownToken.Kind(parse.word(at)),
                range: NSRange(location: start, length: Int(parse.word(at + 4)) - start),
                content: NSRange(location: contentStart, length: Int(parse.word(at + 3)) - contentStart)
            )
        }
    }
}

/// A unit the editor reparses: a top-level block, a top-level list item, or a top-level table's head or one of its
/// rows. `range` is whole lines: the last line's terminator is in, blank lines after it are out.
public struct MarkdownBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph, heading(level: Int), thematicBreak, quote, callout, code, html, item, tableHead, tableRow
        case footnoteDefinition, definition, frontMatter

        /// The code in the low byte and a heading's level in the byte above it, as `core/crates/ffi` writes them.
        init(_ word: UInt32) {
            self = switch word & 0xFF {
            case 0: .paragraph
            case 1: .heading(level: Int(word >> 8))
            case 2: .thematicBreak
            case 3: .quote
            case 4: .callout
            case 5: .code
            case 6: .html
            case 7: .item
            case 8: .tableHead
            case 9: .tableRow
            case 10: .footnoteDefinition
            case 11: .definition
            case 12: .frontMatter
            default: preconditionFailure("block kind \(word)")
            }
        }
    }

    public let kind: Kind
    public let range: NSRange
}

/// A markdown construct. The characters in `range` but outside `content` are its markers.
public struct MarkdownToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int), emphasis, strong, strikethrough, inlineCode, link, image, fencedCode, quote, callout
        case item, taskBox(checked: Bool), tableHead, tableRow, tableCell, footnoteReference, footnoteDefinition
        case definition, inlineMath, displayMath, wikiLink, embed, highlight, comment, tag, frontMatter, html

        /// The code in the low byte and a heading's level or a task box's check in the byte above it, as
        /// `core/crates/ffi` writes them.
        init(_ word: UInt32) {
            self = switch word & 0xFF {
            case 0: .heading(level: Int(word >> 8))
            case 1: .emphasis
            case 2: .strong
            case 3: .strikethrough
            case 4: .inlineCode
            case 5: .link
            case 6: .image
            case 7: .fencedCode
            case 8: .quote
            case 9: .callout
            case 10: .item
            case 11: .taskBox(checked: word >> 8 != 0)
            case 12: .tableHead
            case 13: .tableRow
            case 14: .tableCell
            case 15: .footnoteReference
            case 16: .footnoteDefinition
            case 17: .definition
            case 18: .inlineMath
            case 19: .displayMath
            case 20: .wikiLink
            case 21: .embed
            case 22: .highlight
            case 23: .comment
            case 24: .tag
            case 25: .frontMatter
            case 26: .html
            default: preconditionFailure("token kind \(word)")
            }
        }
    }

    public let kind: Kind
    public let range: NSRange
    public let content: NSRange
}
