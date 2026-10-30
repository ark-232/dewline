import Foundation
import MdCore

/// Words of prose, read from the block map: markers, code, math, front matter, HTML, link destinations and
/// definitions don't count.
enum WordCount {
    private static let skippedBlocks: [MarkdownBlock.Kind] = [.code, .frontMatter, .html, .definition, .thematicBreak]
    private static let skippedSpans: [SyntaxSpan.Kind] = [
        .inlineCode, .fencedCode, .image, .inlineMath, .displayMath, .html, .comment, .frontMatter, .definition, .footnoteReference, .embed, .tag,
    ]

    /// The words in `text`, and the words that start in `selection`.
    static func count(_ text: String, blocks: [BlockMap.Block], selection: NSRange) -> (total: Int, selected: Int) {
        let text = text as NSString
        var skipped = IndexSet()
        for block in blocks {
            if skippedBlocks.contains(block.kind) {
                skipped.insert(integersIn: Range(block.range)!)
                continue
            }
            for span in block.spans {
                let span = span.shifted(by: block.range.location)
                if case .taskBox = span.kind {
                    skipped.insert(integersIn: Range(span.range)!)
                } else if skippedSpans.contains(span.kind) {
                    skipped.insert(integersIn: Range(span.range)!)
                } else {
                    for marker in span.markers { skipped.insert(integersIn: Range(marker)!) }
                }
            }
            for picture in block.rendered {
                skipped.insert(integersIn: Range(picture.shifted(by: block.range.location).range)!)
            }
        }
        var total = 0
        var selected = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, word, _, _ in
            guard !skipped.contains(word.location) else { return }
            total += 1
            if NSLocationInRange(word.location, selection) { selected += 1 }
        }
        return (total, selected)
    }

    /// "1,234 words", or with a selection "12 of 1,234 words".
    static func label(total: Int, selected: Int?) -> String {
        let words = total == 1 ? "word" : "words"
        let all = total.formatted(.number)
        guard let selected else { return "\(all) \(words)" }
        return "\(selected.formatted(.number)) of \(all) \(words)"
    }
}
