import Foundation
import MdCore
import Testing
@testable import Dewline

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// How the map and a fresh parse of `text` differ, if they do.
@MainActor
private func difference(_ map: BlockMap, _ text: NSString) throws -> String? {
    let fresh = try MarkdownParser().parse(text as String)
    let blocks = map.blocks(in: NSRange(location: 0, length: text.length))
    let mapped = blocks.map { "\($0.kind) \($0.range)" }
    let parsed = fresh.blocks.map { "\($0.kind) \($0.range)" }
    if mapped != parsed { return "blocks \(mapped) != \(parsed)" }
    let spans = blocks.flatMap { block in block.spans.map { $0.shifted(by: block.range.location) } }
    let tokens = fresh.tokens.map { SyntaxSpan(kind: $0.kind, range: $0.range, content: $0.content) }
    return spans == tokens ? nil : "spans \(spans) != \(tokens)"
}

@MainActor
struct BlockMapTests {
    static let pieces = [
        "# Title\n", "Setext\n===\n", "Some **strong**, *em*, `code` and ~~gone~~ words.\n", "\n", "\n\n", "- item\n",
        "- [ ] task\n", "1. first\n", "   more\n", "  - nested\n", "> quote\n", "> [!note] Callout\n", "```\nlet x\n```\n",
        "```mermaid\nflowchart LR\n```\n", "~~~\ncode\n~~~\n", "    indented\n", "$$\nx^2\n$$\n", "Cost $x$ and $$y$$.\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n", "| 3 | 4 |\n", "See [^1] and [a] and [b][].\n", "[^1]: A note\n",
        "[a]: /u\n", "[b]: /v \"t\"\n", "---\ntitle: x\n---\n", "<div>\nhtml\n</div>\n", "<!-- c -->\n",
        "[[Page|alias]] ![[embed]] ==mark== %%hidden%% #tag\n", "[link](https://x.y) <https://x.y> ![a](b.png)\n",
        "line\r\n", "---\n", "***\n", "  ", "\t", "é日本🙂 ",
    ]
    static let typed = [
        "", "a", " ", "  ", "    ", "\t", "\n", "\n\n", "- ", "1. ", "> ", "# ", "```", "~~~", "$$", "$", "%%", "==",
        "<div>", "<!--", "-->", "---", "===", "|", "| a |\n|---|", "[a]: /u", "[^1]: n", "[^1]", "[a]", "[[", "]]", "*",
        "**", "_", "~~", "`", "\r\n", "é", "🙂", "#tag",
    ]

    /// Seeded edits of every size over every construct, fed to the map as the editor feeds it: after each, the map
    /// equals a fresh parse, once a provisional map's whole parse lands. PROPTEST_CASES (TEST_RUNNER_PROPTEST_CASES
    /// through xcodebuild) sets the number of edits, 1,000 by default.
    @Test func editsLeaveTheMapAFreshParseWouldGive() throws {
        let edits = ProcessInfo.processInfo.environment["PROPTEST_CASES"].flatMap(Int.init) ?? 1000
        var random = SplitMix(state: 0xB10C_4A9)
        func pick(_ items: [String]) -> String { items[Int(random.next() % UInt64(items.count))] }
        let text = NSMutableString()
        let map = BlockMap()
        var held = 0
        for edit in 0..<edits {
            if edit % 50 == 0 {
                let document = (0..<(10 + Int(random.next() % 30))).map { _ in pick(Self.pieces) }.joined()
                text.setString(document)
                _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: text.length)
            }
            let before = text.copy() as! String
            let location = Int(random.next() % UInt64(text.length + 1))
            let length = min(random.next() % 4 == 0 ? Int(random.next() % 40) : Int(random.next() % 6), text.length - location)
            let replaced = text.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
            let inserted = random.next() % 5 == 0 ? pick(Self.pieces) : pick(Self.typed)
            text.replaceCharacters(in: replaced, with: inserted)
            let count = (inserted as NSString).length
            _ = map.textDidChange(text, edited: NSRange(location: replaced.location, length: count), delta: count - replaced.length)
            if map.isProvisional {
                map.reparseNow()
            } else {
                held += 1
            }
            if let difference = try difference(map, text) {
                Issue.record("edit \(edit): \(inserted.debugDescription) over \(replaced) in \(before.debugDescription): \(difference)")
                return
            }
        }
        print("BlockMapTests: \(held) of \(edits) edits held")
    }

    /// A long text's first screen parses at once and the rest off the main thread, which an edit past the first screen
    /// does not wait for.
    @Test func aLongTextParsesItsFirstScreenNowAndTheRestLater() async throws {
        let text = NSMutableString(string: MarkdownCorpus.text(bytes: 1 << 16))
        let map = BlockMap()
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: text.length)
        #expect(map.parsed < text.length)
        // An edit in the first screen makes the running parse stale, and another runs.
        text.insert("x", at: 0)
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: 1), delta: 1)
        let deadline = ContinuousClock.now + .seconds(10)
        while map.parsed < text.length, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(map.parsed == text.length)
        #expect(try difference(map, text) == nil)

        _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: 0)
        #expect(map.parsed < text.length)
        text.insert("y", at: text.length - 1)
        _ = map.textDidChange(text, edited: NSRange(location: text.length - 2, length: 1), delta: 1)
        #expect(map.parsed == text.length)
        #expect(try difference(map, text) == nil)
    }
}
