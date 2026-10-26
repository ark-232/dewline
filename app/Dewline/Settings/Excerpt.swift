import AppKit

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
        let string = text as NSString
        var heading: String?
        var paragraphs: [(String, [NSRange])] = []
        var fencedCode: String?
        var inlineCode: String?
        var fenced = false
        var lines = 0
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, line, _, stop in
            lines += 1
            guard lines <= 200 else {
                stop.pointee = true
                return
            }
            let source = string.substring(with: line)
            if source.hasPrefix("```") || source.hasPrefix("~~~") {
                fenced.toggle()
                return
            }
            if fenced {
                if fencedCode == nil, !source.trimmingCharacters(in: .whitespaces).isEmpty { fencedCode = source }
                return
            }
            guard let first = source.first else { return }
            let spans = SpikeTokenizer.spans(in: string, line: line)
            if heading == nil, case .heading? = spans.first?.kind {
                heading = string.substring(with: spans[0].content)
            } else if first.isLetter || first.isNumber || "*_`[".contains(first) {
                // Markers come out, and each link's text moves left by the markers before it.
                let markers = spans.flatMap(\.markers)
                func removed(before location: Int) -> Int {
                    markers.filter { NSMaxRange($0) <= location }.reduce(0) { $0 + $1.length }
                }
                let plain = NSMutableString(string: source)
                for marker in markers.sorted(by: { $0.location > $1.location }) {
                    plain.deleteCharacters(in: NSRange(location: marker.location - line.location, length: marker.length))
                }
                let links = spans.filter { $0.kind == .link }.map { span in
                    let start = span.content.location - removed(before: span.content.location)
                    let end = NSMaxRange(span.content) - removed(before: NSMaxRange(span.content))
                    return NSRange(location: start - line.location, length: end - start)
                }
                paragraphs.append((plain as String, links))
            }
            if inlineCode == nil, let span = spans.first(where: { $0.kind == .inlineCode }) {
                inlineCode = string.substring(with: span.content)
            }
            let long = paragraphs.contains { $0.0.count >= 80 }
            if heading != nil, long, fencedCode != nil || paragraphs.count > 20 { stop.pointee = true }
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
