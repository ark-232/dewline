import Foundation
import MdCore
import Testing

struct MarkdownSpansTests {
    @Test func rangesSelectTheirTextThroughNSString() {
        let text = "# Café 🙂\n\nSome **bold 🙂** with `code`, *é* and [a 🙂 link](https://example.com).\n"
        let string = text as NSString
        let spans = markdownSpans(in: text)
        #expect(spans.map(\.kind) == [.heading(level: 1), .strong, .inlineCode, .emphasis, .link])
        #expect(spans.map { string.substring(with: $0.range) } == [
            "# Café 🙂", "**bold 🙂**", "`code`", "*é*", "[a 🙂 link](https://example.com)",
        ])
        #expect(spans.map { string.substring(with: $0.content) } == ["Café 🙂", "bold 🙂", "code", "é", "a 🙂 link"])
    }
}
