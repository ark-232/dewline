import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    init(_ text: String, caret: Int) {
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Empties the view first: a closed window's text system stays alive for a while, still holding the text.
    func close() {
        view.string = ""
        window.close()
    }

    func picture(at location: Int) -> BlockPicture? {
        guard case .picture(let picture, _)? = (view.textStorage!.attribute(.dewlineBlock, at: location, effectiveRange: nil) as? BlockLine)?.role else {
            return nil
        }
        return picture
    }

    /// Restyles the whole text at the selection and describes the first attribute that changed, if any did.
    func restyleChanges() -> String? {
        let storage = view.textStorage!
        let before = NSAttributedString(attributedString: storage)
        view.styler.restyleDocument()
        let keys: [NSAttributedString.Key] = [
            .font, .foregroundColor, .backgroundColor, .paragraphStyle, .underlineStyle, .strikethroughStyle, .kern,
            .dewlineMarkerFont, .dewlineBlock, .dewlineQuote,
        ]
        for offset in 0..<storage.length {
            let old = before.attributes(at: offset, effectiveRange: nil)
            let new = storage.attributes(at: offset, effectiveRange: nil)
            for key in keys where old[key] as? NSObject != new[key] as? NSObject {
                let line = storage.mutableString.substring(with: storage.mutableString.lineRange(for: NSRange(location: offset, length: 0)))
                return "\(key.rawValue) at \(offset), line \(line.debugDescription), selection \(view.selectedRange()): "
                    + "\(old[key].map { "\($0)" } ?? "nil") became \(new[key].map { "\($0)" } ?? "nil")"
            }
        }
        return nil
    }
}

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

@MainActor
@Suite(.serialized)
struct EditRestyleTests {
    /// Return inside a strong span splits its paragraph, and the half after the break keeps none of the span's styling.
    @Test func aLineBreakRestylesTheHalfAfterIt() {
        let editor = Editor("Some **bold words** here\nNext line\n", caret: 11)
        defer { editor.close() }
        editor.view.insertNewline(nil)
        #expect(editor.view.string == "Some **bold\n words** here\nNext line\n")
        #expect(editor.restyleChanges() == nil)
    }

    /// A line break written into the storage before a code span's `*` makes the half after it start an emphasis: its
    /// markers carry the font they show in when the caret reveals them, as `MarkdownStyler.mark` needs.
    /// The break makes a blank line, which ends the code span at it and starts a paragraph with emphasis.
    @Test func aLineBreakInTheStorageStylesTheSpansItMakes() throws {
        let editor = Editor("Code `a\n*b` c* end\nNext\n", caret: 0)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 8, length: 0), with: "\n")
        let text = storage.mutableString
        let tail = text.paragraphRange(for: NSRange(location: 9, length: 0))
        let markers = editor.view.styler.map.blocks(in: tail)
            .flatMap { block in block.spans.flatMap { $0.shifted(by: block.range.location).markers } }
            .filter { NSIntersectionRange($0, tail).length > 0 }
        try #require(!markers.isEmpty)
        for marker in markers {
            #expect(storage.attribute(.dewlineMarkerFont, at: marker.location, effectiveRange: nil) != nil, "marker at \(marker.location)")
        }
        #expect(editor.restyleChanges() == nil)
    }

    /// Return at the end of a block's closing fence takes the caret out of the block, which draws its picture again.
    @Test func returnAfterAClosingFenceRendersTheBlock() async {
        let formula = "$$\n\\frac{a}{b}\n$$"
        let start = 6
        let end = start + formula.utf16.count
        let editor = Editor("Above\n\(formula)\n\nBelow\n", caret: 0)
        defer { editor.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        while editor.picture(at: start) == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(editor.picture(at: start) != nil)
        editor.view.setSelectedRange(NSRange(location: end, length: 0))
        #expect(editor.picture(at: start) == nil, "the caret at the closing fence reveals the source")
        editor.view.insertNewline(nil)
        #expect(editor.view.string == "Above\n\(formula)\n\n\nBelow\n")
        #expect(editor.view.selectedRange() == NSRange(location: end + 1, length: 0))
        #expect(editor.picture(at: start) != nil, "the picture returns once the caret is out")
    }

    /// Seeded random edits in text with spans, headings, quotes and fences, line breaks anywhere and deletes across
    /// them included: after each, a restyle of the whole text changes nothing.
    @Test func editsLeaveWhatAWholeRestyleWouldGive() throws {
        let fragments = [
            "**a**", "*b*", "`c`", "~~d~~", "[e](u)", "_u_", " ", " ", "\n", "\n", "\n", "word", "xy", "# ", "> ", "- ",
            "**", "*", "`", "é", "日本", "👩🏽‍💻", "$$", "```", "\n$$\nx^2\n$$\n", "\n```\nlet **x**\n```\n",
        ]
        let typed = ["a", "*", "**", " ", "`", "~~", "é", "日", "👩🏽‍💻", "_", "xyz", "[l](m)", "# ", "$$"]
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.restyle"))
        defer { pasteboard.releaseGlobally() }
        for seed in UInt64(1)...12 {
            var random = SplitMix(state: seed)
            func pick(_ items: [String]) -> String { items[Int(random.next() % UInt64(items.count))] }
            func offset(upTo limit: Int) -> Int { Int(random.next() % UInt64(limit + 1)) }
            let editor = Editor((0..<(25 + Int(random.next() % 20))).map { _ in pick(fragments) }.joined(), caret: 0)
            defer { editor.close() }
            let view = editor.view
            let storage = try #require(view.textStorage)
            // Each edit gets its own undo group, as each event does in the app; NSUndoManager raises on a
            // registration outside a group.
            let undo = view.styler.undoManager
            try #require(undo.groupingLevel == 0)
            undo.groupsByEvent = false
            defer { undo.groupsByEvent = true }
            func grouped(_ body: () -> Void) {
                undo.beginUndoGrouping()
                body()
                undo.endUndoGrouping()
            }
            for step in 0..<60 {
                let kind = random.next() % 12
                if kind != 7, kind != 8, random.next() % 2 == 0 {
                    let location = offset(upTo: storage.length)
                    view.setSelectedRange(NSRange(location: location, length: min(Int(random.next() % 4), storage.length - location)))
                }
                switch kind {
                case 0, 1: grouped { view.insertText(pick(typed), replacementRange: view.selectedRange()) }
                case 2, 3: grouped { view.insertNewline(nil) }
                case 4: grouped { view.deleteBackward(nil) }
                case 5: grouped { view.deleteForward(nil) }
                case 6:
                    pasteboard.clearContents()
                    pasteboard.setString((0...(random.next() % 3)).map { _ in pick(fragments) }.joined(), forType: .string)
                    grouped { _ = view.readSelection(from: pasteboard, type: .string) }
                case 7: if undo.canUndo { undo.undo() }
                case 8: if undo.canRedo { undo.redo() }
                case 9:
                    // Writes into the storage register no undo, so the history before them no longer applies.
                    let location = offset(upTo: storage.length)
                    let length = min(Int(random.next() % 4), storage.length - location)
                    storage.replaceCharacters(in: NSRange(location: location, length: length), with: pick(fragments))
                    undo.removeAllActions()
                case 10:
                    grouped {
                        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                        if random.next() % 2 == 0 {
                            view.insertText("か", replacementRange: view.markedRange())
                        } else {
                            view.unmarkText()
                        }
                    }
                default: break
                }
                if let change = editor.restyleChanges() {
                    Issue.record("seed \(seed), step \(step), edit \(kind): \(change)")
                    break
                }
            }
        }
    }
}
