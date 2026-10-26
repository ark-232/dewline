import Foundation
import Testing
@testable import Dewline

struct BlockScannerTests {
    static func sources(_ text: String) -> [String] {
        BlockScanner.scan(text as NSString).blocks.map(\.source)
    }

    @Test func fencesPairAsInCommonMark() {
        #expect(Self.sources("```mermaid\nflowchart LR\n```") == ["flowchart LR"])
        #expect(Self.sources("~~~~ mermaid\na\n~~~\n~~~~~") == ["a\n~~~"])
        // A line with an info string cannot close a fence, so this mermaid fence is inside code.
        #expect(Self.sources("```\n```mermaid\na\n```").isEmpty)
        #expect(Self.sources("```mermaid\nnever closed").isEmpty)
        #expect(Self.sources("```js\nlet a = 1\n```\n```mermaid\npie\n```") == ["pie"])
    }

    @Test func dollarsMakeABlockOnlyOnTheirOwnLines() {
        #expect(Self.sources("$$x^2$$") == ["x^2"])
        #expect(Self.sources("$$\n\\frac{a}{b}\n$$") == ["\\frac{a}{b}"])
        #expect(Self.sources("$$x$$ and more\n$$y$$") == ["y"])
        #expect(Self.sources("Cost: $$5\n$$").isEmpty)
    }

    @Test func anImageIsABlockOnlyAloneInItsParagraph() {
        #expect(Self.sources("Text\n\n![a dot](img/dot.png)\n\nMore") == ["img/dot.png"])
        #expect(Self.sources("Text\n![a dot](dot.png)").isEmpty)
        #expect(Self.sources("![remote](https://example.com/dot.png)").isEmpty)
        #expect(Self.sources("![absolute](/tmp/dot.png)").isEmpty)
    }

    @Test @MainActor func editsAwayFromBlocksShiftThemAndEditsThatMakeOrBreakOneReparse() {
        let text = NSMutableString(string: "Intro\n\n```mermaid\nA\n```\n\nEnd\n")
        let map = BlockMap()
        let rendered = { map.renderedBlocks(in: NSRange(location: 0, length: text.length)) }
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: text.length)
        #expect(rendered().map(\.range) == [NSRange(location: 7, length: 16)])
        text.insert("x", at: 0)
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: 1), delta: 1)
        #expect(rendered().map(\.range) == [NSRange(location: 8, length: 16)])
        text.insert("B", at: 20)
        #expect(map.textDidChange(text, edited: NSRange(location: 20, length: 1), delta: 1) == NSRange(location: 8, length: 18))
        #expect(rendered().map(\.range) == [NSRange(location: 8, length: 17)])
        #expect(rendered().map(\.source) == ["AB"])
        // A fence opened above runs on past its window, which leaves the block for the whole parse.
        text.insert("```\n", at: 0)
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: 4), delta: 4)
        #expect(map.isProvisional)
        map.reparseNow()
        #expect(rendered().isEmpty)
    }

    @Test @MainActor func frontMatterAndIndentedCodeAreCode() {
        let text = NSMutableString(string: "---\ntitle: x\n\nPara\n\n    code\n- item\n\n    more\n")
        let map = BlockMap()
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: text.length)
        func code(_ word: String) -> Bool {
            map.isCode(text.range(of: word))
        }
        #expect(!code("title") && code("code") && !code("more"))
        text.insert("---\n", at: 13)
        _ = map.textDidChange(text, edited: NSRange(location: 13, length: 4), delta: 4)
        #expect(map.isProvisional)
        map.reparseNow()
        #expect(code("title") && !code("Para"))
    }

    @Test @MainActor func textBesideAnImageEndsItsBlock() {
        let text = NSMutableString(string: "Text\n\n![a](b.png)\n\nMore")
        let map = BlockMap()
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: text.length)
        #expect(map.renderedBlocks(in: NSRange(location: 0, length: text.length)).map(\.source) == ["b.png"])
        text.insert("x", at: 18)
        #expect(map.textDidChange(text, edited: NSRange(location: 18, length: 1), delta: 1) == NSRange(location: 6, length: 14))
        #expect(map.renderedBlocks(in: NSRange(location: 0, length: text.length)).isEmpty)
    }
}
