import AppKit
import Testing
@testable import Dewline

/// A text and caret written as one string, `|` before the caret's character.
@MainActor private final class Buffer: VimHost {
    let text: NSMutableString
    var vimSelection: NSRange
    var vimClipboard: String?
    var saves = 0
    var closes = 0
    private var replaced = false
    private var history: [(String, NSRange)] = []
    private var future: [(String, NSRange)] = []
    let vim = VimEngine()

    init(_ marked: String) {
        vimSelection = NSRange(location: (marked as NSString).range(of: "|").location, length: 0)
        text = NSMutableString(string: marked.replacingOccurrences(of: "|", with: ""))
    }

    var marked: String {
        let marked = NSMutableString(string: text)
        marked.insert("|", at: vimSelection.location)
        return marked as String
    }

    var vimText: NSString { text }

    func vimReplace(_ range: NSRange, with string: String) {
        text.replaceCharacters(in: range, with: string)
        replaced = true
    }

    func vimUndo() {
        guard let (old, selection) = history.popLast() else { return }
        future.append((text as String, vimSelection))
        text.setString(old)
        vimSelection = selection
    }

    func vimRedo() {
        guard let (new, selection) = future.popLast() else { return }
        history.append((text as String, vimSelection))
        text.setString(new)
        vimSelection = selection
    }

    func vimSave() { saves += 1 }
    func vimClose() { closes += 1 }

    /// Each key is one event and one undo step, as in the app; insert mode types the key itself, as the text view does.
    func type(_ keys: String) {
        for key in tokens(keys) {
            if vim.mode == .insert, key != "<Esc>" {
                history.append((text as String, vimSelection))
                text.insert(key, at: vimSelection.location)
                vimSelection.location += key.utf16.count
                continue
            }
            let before = (text as String, vimSelection)
            replaced = false
            vim.handle(key, in: self)
            if replaced {
                history.append(before)
                future = []
            }
        }
    }
}

private func tokens(_ keys: String) -> [String] {
    var tokens: [String] = []
    var rest = Substring(keys)
    while let first = rest.first {
        if first == "<", let close = rest.firstIndex(of: ">"), rest.distance(from: rest.startIndex, to: close) > 1 {
            tokens.append(String(rest[...close]))
            rest = rest[rest.index(after: close)...]
        } else {
            tokens.append(String(first))
            rest = rest.dropFirst()
        }
    }
    return tokens
}

struct VimCase: Sendable, CustomTestStringConvertible {
    let keys: String
    let start: String
    let expected: String
    var testDescription: String { "\(keys) on \(start.debugDescription)" }
}

private func row(_ keys: String, _ start: String, _ expected: String) -> VimCase {
    VimCase(keys: keys, start: start, expected: expected)
}

/// The conformance table: keys, the text and caret before, and the text and caret after.
private let table: [VimCase] = [
    // Motions and counts
    row("l", "|abc", "a|bc"),
    row("3l", "|abcdef", "abc|def"),
    row("l", "ab|c", "ab|c"),
    row("h", "ab|c", "a|bc"),
    row("j", "a|bc\ndef", "abc\nd|ef"),
    row("k", "abc\nde|f", "ab|c\ndef"),
    row("j", "abc|d\nxy", "abcd\nx|y"),
    row("2j", "|a\nb\nc", "a\nb\n|c"),
    row("w", "|foo bar", "foo |bar"),
    row("2w", "|foo bar baz", "foo bar |baz"),
    row("w", "|foo.bar", "foo|.bar"),
    row("w", "|foo\n\nbar", "foo\n|\nbar"),
    row("b", "foo ba|r", "foo |bar"),
    row("2b", "foo bar ba|z", "foo |bar baz"),
    row("e", "|foo bar", "fo|o bar"),
    row("e", "fo|o bar", "foo ba|r"),
    row("0", "  fo|o", "|  foo"),
    row("^", "  fo|o", "  |foo"),
    row("$", "|foo bar", "foo ba|r"),
    row("gg", "abc\nd|ef", "|abc\ndef"),
    row("G", "a|bc\n  def\n", "abc\n  |def\n"),
    row("2G", "a\nb\n|c", "a\n|b\nc"),
    row("fb", "|foo bar boo", "foo |bar boo"),
    row("2fb", "|foo bar boo", "foo bar |boo"),
    row("tb", "|foo bar", "foo| bar"),
    row("%", "|(a [b])", "(a [b]|)"),
    row("%", "(a [b]|)", "|(a [b])"),
    row("<Right><Down>", "|ab\ncd", "ab\nc|d"),
    // Operators over motions
    row("dw", "|foo bar", "|bar"),
    row("d2w", "|a b c", "|c"),
    row("2dw", "|a b c", "|c"),
    row("dw", "foo |bar\nbaz", "foo| \nbaz"),
    row("de", "|foo bar", "| bar"),
    row("db", "foo b|ar", "foo |ar"),
    row("d$", "fo|o bar", "f|o"),
    row("d0", "foo b|ar", "|ar"),
    row("d3l", "|abcd", "|d"),
    row("dd", "a\n|b\nc", "a\n|c"),
    row("2dd", "|a\nb\nc", "|c"),
    row("dd", "a\n|b", "|a"),
    row("dj", "|a\nb\nc", "|c"),
    row("dk", "a\n|b\nc", "|c"),
    row("dgg", "a\nb\n|c\nd", "|d"),
    row("dG", "a\n|b\nc", "|a"),
    row("dfb", "|foo bar", "|ar"),
    row("dtb", "|foo bar", "|bar"),
    row("d%", "x|(a)y", "x|y"),
    row("cwxy<Esc>", "|foo bar", "x|y bar"),
    row("c2wz<Esc>", "|a b c", "|z c"),
    row("ccnew<Esc>", "a\n|old\nb", "a\nne|w\nb"),
    row("c$z<Esc>", "ab|cd", "ab|z"),
    row("yyp", "|ab\ncd", "ab\n|ab\ncd"),
    row("ywP", "|foo bar", "foo| foo bar"),
    row(">>", "|a", "    |a"),
    row("<<", "    |a", "|a"),
    row(">j", "|a\nb", "    |a\n    b"),
    row("3>>", "|a\nb\nc\nd", "    |a\n    b\n    c\nd"),
    // Text objects
    row("diw", "foo b|ar baz", "foo | baz"),
    row("daw", "foo b|ar baz", "foo |baz"),
    row("ci\"x<Esc>", "say \"hi| there\" now", "say \"|x\" now"),
    row("da\"", "a \"b|c\" d", "a |d"),
    row("di(", "f(a, |b)", "f(|)"),
    row("da(", "f(a|b)x", "f|x"),
    row("dib", "(a (|b) c)", "(a (|) c)"),
    row("dip", "a\n|b\n\nc", "|\nc"),
    row("dap", "a\n|b\n\nc", "|c"),
    row("yiwP", "foo b|ar", "foo ba|rbar"),
    // Single commands
    row("x", "a|bc", "a|c"),
    row("3x", "|abcd", "|d"),
    row("x", "ab|c", "a|b"),
    row("rz", "a|bc", "a|zc"),
    row("3rz", "|abcd", "zz|zd"),
    row("ox<Esc>", "|a\nb", "a\n|x\nb"),
    row("Ox<Esc>", "a\n|b", "a\n|x\nb"),
    row("J", "|a\n  b", "a| b"),
    row("3J", "|a\nb\nc", "a b| c"),
    row("xp", "|abc", "b|ac"),
    row("ddP", "a\n|b", "|b\na"),
    row("ddp", "|a\nb", "b\n|a"),
    row("ix<Esc>", "a|b", "a|xb"),
    row("ax<Esc>", "a|b", "ab|x"),
    row("Ix<Esc>", "  a|b", "  |xab"),
    row("Ax<Esc>", "|ab", "ab|x"),
    // Undo and redo
    row("xu", "a|bc", "a|bc"),
    row("xxuu", "|abc", "|abc"),
    row("xu<C-r>", "a|bc", "a|c"),
    row("ddu", "a\n|b\nc", "a\n|b\nc"),
    // Dot repeat
    row("x.", "|abcd", "|cd"),
    row("dw.", "|a b c", "|c"),
    row("3x2.", "|abcdefg", "|fg"),
    row("cwX<Esc>w.", "|foo bar", "X |X"),
    row("A!<Esc>j.", "|a\nb", "a!\nb|!"),
    row(">>.", "|a", "        |a"),
    row("dd.", "|a\nb\nc", "|c"),
    // Visual and visual line
    row("vld", "|abc", "|c"),
    row("vjd", "a|bc\ndef", "a|f"),
    row("Vjd", "|a\nb\nc", "|c"),
    row("viwd", "foo b|ar baz", "foo | baz"),
    row("Vyp", "|a", "a\n|a"),
    row("Vj>", "|a\nb", "    |a\n    b"),
    row("vcx<Esc>", "|ab", "|xb"),
    row("vlly", "a|bcd", "a|bcd"),
    row("vl<Esc>", "a|bc", "ab|c"),
    row("vlohd", "ab|cde", "a|e"),
    // Search
    row("/bar<CR>", "|foo bar bar", "foo |bar bar"),
    row("/bar<CR>n", "|foo bar bar", "foo bar |bar"),
    row("/bar<CR>nn", "|foo bar bar", "foo |bar bar"),
    row("?foo<CR>", "foo foo |x", "foo |foo x"),
    row("?foo<CR>n", "foo foo |x", "|foo foo x"),
    row("/foo<CR>N", "|x foo foo", "x foo |foo"),
    // Marked text never reaches here; an unknown key or an escaped command does nothing.
    row("d<Esc>x", "|ab", "|b"),
    row("Q", "|ab", "|ab"),
]

@MainActor struct VimTests {
    @Test(arguments: table) func conformance(_ row: VimCase) {
        let buffer = Buffer(row.start)
        buffer.type(row.keys)
        #expect(buffer.marked == row.expected)
        #expect(buffer.vim.mode == .normal)
    }

    @Test func modes() {
        let buffer = Buffer("|ab\ncd")
        buffer.type("v")
        #expect(buffer.vim.mode == .visual && buffer.vimSelection == NSRange(location: 0, length: 1))
        buffer.type("V")
        #expect(buffer.vim.mode == .visualLine && buffer.vimSelection == NSRange(location: 0, length: 3))
        buffer.type("V")
        #expect(buffer.vim.mode == .normal && buffer.vim.status == "NORMAL")
        buffer.type("i")
        #expect(buffer.vim.mode == .insert && buffer.vim.status == "INSERT")
        buffer.type("<Esc>2d")
        #expect(buffer.vim.status == "NORMAL  2d")
        buffer.type("<Esc>/ab")
        #expect(buffer.vim.status == "/ab")
    }

    @Test func clipboardRegister() {
        let buffer = Buffer("|foo bar")
        buffer.type("\"+yiw")
        #expect(buffer.vimClipboard == "foo")
        buffer.vimClipboard = "zap"
        buffer.type("$\"+p")
        #expect(buffer.marked == "foo barza|p")
        buffer.type("0yiwP")
        #expect(buffer.marked == "fo|ofoo barzap" && buffer.vimClipboard == "zap")
    }

    @Test func saveAndClose() {
        let buffer = Buffer("|a")
        buffer.type(":w<CR>")
        #expect(buffer.saves == 1 && buffer.closes == 0)
        buffer.type(":q<CR>")
        #expect(buffer.closes == 1)
        buffer.type(":wq<CR>")
        #expect(buffer.saves == 2 && buffer.closes == 2 && buffer.text == "a")
    }

    @Test func settingPersists() throws {
        let suite = "dev.arkwerx.dewline.tests.vim"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        #expect(!store.vimMode)
        store.vimMode = true
        #expect(ThemeStore(defaults: defaults).vimMode)
    }

    private func press(_ key: String, _ view: EditorTextView, code: UInt16 = 0) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    @Test func markedTextIsNeverACommand() {
        let view = EditorTextView()
        view.string = "one\ntwo\n"
        view.vim = VimEngine()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let undo = view.styler.undoManager
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        for key in ["d", "d", "x"] {
            undo.beginUndoGrouping()
            view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            press(key, view)
            undo.endUndoGrouping()
            #expect(view.vim?.status == "NORMAL")
        }
        #expect(view.string.contains("one\ntwo\n"))
    }

    @Test func undoRestoresTheExactText() {
        let view = EditorTextView()
        let original = "# Title\n\nfoo bar\n  baz *qux*\n"
        view.string = original
        view.vim = VimEngine()
        let undo = view.styler.undoManager
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        for command in ["dd", "dw", "x", "J", ">>", "yyp", "rZ", "diw", "dap", "ox"] {
            view.setSelectedRange(NSRange(location: 9, length: 0))
            for key in command.map(String.init) {
                undo.beginUndoGrouping()
                press(key, view)
                undo.endUndoGrouping()
            }
            if view.vim?.mode == .insert { press("\u{1b}", view, code: 53) }
            #expect(view.string != original, "\(command)")
            while undo.canUndo { press("u", view) }
            #expect(view.string == original, "\(command)")
        }
    }
}
