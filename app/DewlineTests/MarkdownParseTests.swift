import AppKit
import MdCore
import Testing

struct MarkdownParseTests {
    // The document of records_golden in core/crates/ffi, whose records this decodes.
    @Test func recordsDecodeToRangesThatSelectTheirTextThroughNSString() throws {
        let text = "# Café 🙂\n\n- [x] **done** [a]\n\n[a]: /u\n"
        let string = text as NSString
        let parse = try MarkdownParser().parse(text)
        #expect(parse.holds)
        #expect(parse.blocks.map(\.kind) == [.heading(level: 1), .item, .definition])
        #expect(parse.blocks.map { string.substring(with: $0.range) } == ["# Café 🙂\n", "- [x] **done** [a]\n", "[a]: /u\n"])
        #expect(parse.tokens.map(\.kind) == [.heading(level: 1), .item, .taskBox(checked: true), .strong, .link, .definition])
        #expect(parse.tokens.map { string.substring(with: $0.range) } == [
            "# Café 🙂", "- [x] **done** [a]", "[x]", "**done**", "[a]", "[a]: /u",
        ])
        #expect(parse.tokens.map { string.substring(with: $0.content) } == ["Café 🙂", "[x] **done** [a]", "x", "done", "a", "a"])
    }

    @Test func windowsResolveTheLabelsOfTheLastWholeParse() throws {
        let parser = MarkdownParser()
        let window = { try #require(try parser.parse(window: "See [a].\n", next: "", atStart: false, row: false)) }
        #expect(try window().tokens.isEmpty)
        _ = try parser.parse("[a]: /u\n\nSee [a].\n")
        #expect(try window().tokens.map(\.kind) == [.link])
        #expect(try window().holds)
        #expect(try parser.parse(window: String(repeating: "a", count: 4096), next: "\n", atStart: false, row: false) == nil)
    }

    @Test func textStorageTextKeepsItsUTF16Offsets() throws {
        let storage = NSTextStorage(string: "Café 🙂 **bold**\n")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSString(characters: [0xD800], length: 1) as String)
        let parse = try MarkdownParser().parse(storage.string)
        #expect(parse.tokens.map(\.kind) == [.strong])
        #expect(parse.tokens.map { (storage.string as NSString).substring(with: $0.range) } == ["**bold**"])
    }

    @Test func aPanicInTheParserThrows() throws {
        let parser = MarkdownParser()
        let error = #expect(throws: (any Error).self) { try parser.panicForTest() }
        #expect(String(describing: error).contains("a test asked for a panic"))
        #expect(try parser.parse("# a\n").tokens.map(\.kind) == [.heading(level: 1)])
    }
}
