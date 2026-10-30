import AppKit
import MdCore

/// What the Settings previews set: the frontmost document's first heading, its first paragraph of prose (the first
/// one of 80 characters or more, if any) with the markers removed and its links marked, and its first line of code; a
/// sample stands in for anything missing.
struct Excerpt {
    var heading = "Dewline 1.0 launch plan"
    var paragraph = "Ship the notarized build to the first forty testers. Public beta opens on 2 December, after the dry run. Steps in the release checklist."
    var links = [NSRange(location: 118, length: 17)]
    /// A few words to show the selection on.
    var selection = NSRange(location: 71, length: 13)
    var code = "xcodebuild -scheme Dewline"

    @MainActor static var open: Excerpt {
        var excerpt = Excerpt()
        guard let text = (NSApp.orderedDocuments.first as? MarkdownDocument)?.text else { return excerpt }
        // The first 200 lines.
        var end = text.startIndex
        for _ in 0..<200 where end < text.endIndex {
            end = text[end...].firstIndex(where: \.isNewline).map(text.index(after:)) ?? text.endIndex
        }
        let top = String(text[..<end])
        guard let parse = try? MarkdownParser().parse(top) else { return excerpt }
        let string = top as NSString
        var heading: String?
        var paragraphs: [(String, [NSRange])] = []
        var fencedCode: String?
        var inlineCode: String?
        var next = 0
        for block in parse.blocks {
            var spans: [MarkdownToken] = []
            while next < parse.tokens.count, parse.tokens[next].range.location < NSMaxRange(block.range) {
                spans.append(parse.tokens[next])
                next += 1
            }
            let source = string.substring(with: block.range).trimmingCharacters(in: .newlines)
            switch block.kind {
            case .heading:
                if heading == nil, let span = spans.first { heading = string.substring(with: span.content) }
            case .code:
                if fencedCode == nil, let fence = spans.first(where: { $0.kind == .fencedCode }) {
                    fencedCode = string.substring(with: fence.content).split(whereSeparator: \.isNewline)
                        .first { !$0.allSatisfy(\.isWhitespace) }.map(String.init)
                }
            case .paragraph:
                guard let first = source.first, first.isLetter || first.isNumber || "*_`[".contains(first) else { break }
                // Markers come out, and each link's text moves left by the markers before it.
                let markers = spans.filter { [.emphasis, .strong, .strikethrough, .inlineCode, .link].contains($0.kind) }.flatMap { span in
                    [NSRange(location: span.range.location, length: span.content.location - span.range.location),
                     NSRange(location: NSMaxRange(span.content), length: NSMaxRange(span.range) - NSMaxRange(span.content))]
                }.filter { $0.length > 0 }
                func removed(before location: Int) -> Int {
                    markers.filter { NSMaxRange($0) <= location }.reduce(0) { $0 + $1.length }
                }
                let plain = NSMutableString(string: source)
                for marker in markers.sorted(by: { $0.location > $1.location }) {
                    plain.deleteCharacters(in: NSRange(location: marker.location - block.range.location, length: marker.length))
                }
                plain.replaceOccurrences(of: "\n", with: " ", range: NSRange(location: 0, length: plain.length))
                let links = spans.filter { $0.kind == .link }.map { span in
                    let start = span.content.location - removed(before: span.content.location)
                    let end = NSMaxRange(span.content) - removed(before: NSMaxRange(span.content))
                    return NSRange(location: start - block.range.location, length: end - start)
                }
                paragraphs.append((plain as String, links))
            default:
                break
            }
            if inlineCode == nil, let span = spans.first(where: { $0.kind == .inlineCode }) {
                inlineCode = string.substring(with: span.content)
            }
            let long = paragraphs.contains { $0.0.count >= 80 }
            if heading != nil, long, fencedCode != nil || paragraphs.count > 20 { break }
        }
        if let heading { excerpt.heading = heading }
        if let paragraph = paragraphs.first(where: { $0.0.count >= 80 }) ?? paragraphs.first {
            (excerpt.paragraph, excerpt.links) = paragraph
            let text = excerpt.paragraph as NSString
            var words: [NSRange] = []
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, word, _, _ in
                words.append(word)
            }
            excerpt.selection = words.count > 6 ? NSUnionRange(words[4], words[6]) : NSRange(location: 0, length: 0)
        }
        if let code = fencedCode ?? inlineCode { excerpt.code = code }
        return excerpt
    }
}
