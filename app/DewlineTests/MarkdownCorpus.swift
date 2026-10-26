import Foundation

/// Deterministic markdown shaped like notes: headings, paragraphs with inline markup about once per sentence,
/// lists, quotes, fenced code, links, and some CJK and emoji.
struct MarkdownCorpus {
    private static let vocabulary = """
        the a every other first last quiet careful small open slow warm cold north old new plain
        note draft agent file change line editor river morning plan review merge snapshot window garden
        light stone paper signal map road table column word page story day night season harbor market
        letter question answer reason number pattern system version history branch commit folder image
        keeps writes reads opens moves holds turns waits checks saves finds shows follows changes under
        over between after before beside through against toward without
        """.split(whereSeparator: \.isWhitespace).map(String.init)
    private static let cjk = ["日本語の文章です", "今日は静かな朝でした", "変更は保存されています", "中文段落用于测试", "编辑器保持原样", "한국어 문장도 있습니다"]
    private static let code = [
        "let total = items.reduce(0, +)",
        "for line in text.split(separator: \"\\n\") {",
        "    print(line)",
        "}",
        "func area(width: Double, height: Double) -> Double { width * height }",
        "var cache: [String: Int] = [:]",
        "guard let file = files.first else { return }",
        "let max_lines = 1_000",
        "cargo test --workspace --locked",
    ]

    /// At least `bytes` of UTF-8, the same on every run.
    static func text(bytes: Int) -> String {
        var corpus = MarkdownCorpus()
        var text = ""
        while text.utf8.count < bytes {
            text += corpus.block()
        }
        return text
    }

    private var state: UInt64 = 0

    /// SplitMix64, so the corpus does not depend on the standard library's random algorithms.
    private mutating func pick(_ count: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(count))
    }

    private mutating func any(_ options: [String]) -> String {
        options[pick(options.count)]
    }

    private mutating func block() -> String {
        switch pick(20) {
        case 0, 1:
            return String(repeating: "#", count: 1 + pick(3)) + " " + words(2 + pick(4)).joined(separator: " ") + "\n\n"
        case 2, 3, 4:
            let ordered = pick(2) == 0
            return (1...(3 + pick(4))).map { (ordered ? "\($0). " : "- ") + sentence() + "\n" }.joined() + "\n"
        case 5:
            return (0..<(1 + pick(3))).map { _ in "> " + sentence() + "\n" }.joined() + "\n"
        case 6, 7:
            let lines = (0..<(3 + pick(6))).map { _ in any(Self.code) + "\n" }
            return "```" + any(["swift", "rust", "sh", ""]) + "\n" + lines.joined() + "```\n\n"
        case 8:
            return (0..<(2 + pick(3))).map { _ in pick(2) == 0 ? "**\(any(Self.cjk))**。" : any(Self.cjk) + "。" }.joined() + "\n\n"
        default:
            return (0..<(2 + pick(5))).map { _ in sentence() }.joined(separator: " ") + "\n\n"
        }
    }

    private mutating func words(_ count: Int) -> [String] {
        var words = (0..<count).map { _ in any(Self.vocabulary) }
        words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
        return words
    }

    private mutating func sentence() -> String {
        var words = words(6 + pick(10))
        let start = pick(words.count - 1)
        let marked = start...(start + pick(2))
        let inner = words[marked].joined(separator: " ")
        let wrapped: String? = switch pick(9) {
        case 0, 1: "**\(inner)**"
        case 2: "*\(inner)*"
        case 3: "_\(inner)_"
        case 4: "~~\(inner)~~"
        case 5: "`\(inner)`"
        case 6, 7: "[\(inner)](https://example.com/notes/\(words[start].lowercased()))"
        default: nil
        }
        if let wrapped { words.replaceSubrange(marked, with: [wrapped]) }
        return words.joined(separator: " ") + any([".", ".", ".", ".", ".", "?", "!", " 🙂.", " 🚀", " 👩‍💻."])
    }
}
