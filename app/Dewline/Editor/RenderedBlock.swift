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
