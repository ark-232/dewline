import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let variant: TextKitVariant
    let window: NSWindow
    let view: EditorTextView

    init(_ variant: TextKitVariant, _ text: String, caret: Int) {
        self.variant = variant
        let scrollView = EditorTextView.scrollView(variant: variant)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        place(caret)
    }

    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    func rect(_ location: Int, _ length: Int) -> NSRect {
        view.firstRect(forCharacterRange: NSRange(location: location, length: length), actualRange: nil)
    }

    /// Ranges the spell checker flagged, read from whichever layout manager the variant uses.
    var misspellings: [NSRange] {
        var ranges: [NSRange] = []
        if let layout = view.textLayoutManager {
            let content = layout.textContentManager!
            let start = content.documentRange.location
            layout.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, textRange in
                if let state = attributes[.spellingState] as? Int, state & NSAttributedString.SpellingState.spelling.rawValue != 0 {
                    let location = content.offset(from: start, to: textRange.location)
                    ranges.append(NSRange(location: location, length: content.offset(from: textRange.location, to: textRange.endLocation)))
                }
                return true
            }
        } else {
            let layout = view.layoutManager!
            var index = 0
            while index < view.string.utf16.count {
                var effective = NSRange()
                let state = layout.temporaryAttribute(.spellingState, atCharacterIndex: index, effectiveRange: &effective) as? Int ?? 0
                if state & NSAttributedString.SpellingState.spelling.rawValue != 0 { ranges.append(effective) }
                index = NSMaxRange(effective)
            }
        }
        return ranges
    }

    var flagged: IndexSet {
        misspellings.reduce(into: IndexSet()) { $0.insert(integersIn: Range($1)!) }
    }

    /// Whether the opening `**` of `The **soft** day` takes space: the caret after it sits right of the caret before it.
    var opensRevealed: Bool {
        rect(6, 0).minX - rect(4, 0).minX > 2
    }

    func expectTextKitUnchanged() {
        #expect((view.textLayoutManager != nil) == (variant == .textKit2))
    }
}

@MainActor
struct HideSyntaxTests {
    static let soft = "The **soft** day"

    @Test(arguments: TextKitVariant.allCases)
    func editingKeepsTheExactString(_ variant: TextKitVariant) {
        let text = "# Title\n\nThe **soft** day, *quiet* `code` ~~gone~~ [link](https://example.com) _too_.\n"
        let editor = Editor(variant, text, caret: 0)
        #expect(editor.view.string == text)
        for caret in 0...text.utf16.count {
            editor.place(caret)
            #expect(editor.view.string == text)
        }
        editor.place(17)
        editor.view.insertText("x", replacementRange: editor.view.selectedRange())
        #expect(editor.view.string == text.replacingOccurrences(of: "soft", with: "soxft"))
        editor.view.styler.undoManager.endUndoGrouping()
        editor.window.tryToPerform(Selector(("undo:")), with: nil)
        #expect(editor.view.string == text)
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func hiddenMarkersTakeNoSpace(_ variant: TextKitVariant) {
        let editor = Editor(variant, "\(Self.soft)\nThe soft day\n", caret: 30)
        for marker in [4, 10] {
            let width = editor.rect(marker, 2).width
            #expect(width <= 0.5, "hidden marker at \(marker) is \(width) pt wide")
        }
        #expect(abs(editor.rect(6, 4).minX - editor.rect(3, 1).maxX) <= 0.5)
        #expect(abs(editor.rect(12, 1).minX - editor.rect(6, 4).maxX) <= 0.5)
        editor.place(7)
        for marker in [4, 10] {
            let width = editor.rect(marker, 2).width
            #expect(width > 2, "revealed marker at \(marker) is \(width) pt wide")
        }
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func arrowKeysVisitEveryOffset(_ variant: TextKitVariant) {
        let editor = Editor(variant, Self.soft, caret: 0)
        let length = Self.soft.utf16.count
        let moves = [(editor.view.moveRight, Array(0...length)), (editor.view.moveLeft, Array((0...length).reversed()))]
        for (move, path) in moves {
            var visited = [editor.view.selectedRange().location]
            for _ in 0..<length {
                move(nil)
                let caret = editor.view.selectedRange().location
                visited.append(caret)
                #expect(editor.opensRevealed == (4...12).contains(caret), "caret at \(caret)")
            }
            #expect(visited == path)
        }
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func wordSelectionStopsAtTheMarkers(_ variant: TextKitVariant) {
        let editor = Editor(variant, Self.soft, caret: 16)
        let word = editor.view.selectionRange(forProposedRange: NSRange(location: 8, length: 0), granularity: .selectByWord)
        #expect(word == NSRange(location: 6, length: 4))
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func hitTestingFindsTheRenderedWord(_ variant: TextKitVariant) {
        let editor = Editor(variant, "\(Self.soft)\n", caret: 17)
        for word in [6, 13] {
            let glyph = editor.rect(word, 1)
            #expect(editor.view.characterIndex(for: NSPoint(x: glyph.midX, y: glyph.midY)) == word)
        }
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func compositionDefersStylingUntilCommit(_ variant: TextKitVariant) {
        let editor = Editor(variant, "\(Self.soft)\n", caret: 8)
        let view = editor.view
        let storage = view.textStorage!
        let styled = (0..<17).map { storage.attributes(at: $0, effectiveRange: nil) as NSDictionary }
        let restyles = view.styler.restyles
        for composed in ["か", "かな"] {
            let length = composed.utf16.count
            view.setMarkedText(composed, selectedRange: NSRange(location: length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(view.markedRange() == NSRange(location: 8, length: length))
            let now = (0..<17).map { storage.attributes(at: $0 < 8 ? $0 : $0 + length, effectiveRange: nil) as NSDictionary }
            #expect(now == styled)
        }
        #expect(view.styler.restyles == restyles)
        let marked = view.markedRange()
        let rect = view.firstRect(forCharacterRange: marked, actualRange: nil)
        let line = editor.rect(0, 4)
        #expect(rect.height > 0)
        #expect(rect.minY >= line.minY - 0.5 && rect.maxY <= line.maxY + 0.5, "\(rect) off the caret's line \(line)")
        view.insertText("かな", replacementRange: marked)
        #expect(view.string == "The **soかなft** day\n")
        #expect(!view.hasMarkedText())
        #expect(view.styler.restyles == restyles + 1)
        let font = storage.attribute(.font, at: 8, effectiveRange: nil) as! NSFont
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func accessibilityReadsTheSource(_ variant: TextKitVariant) {
        let text = "# Title\n\(Self.soft)\n"
        let editor = Editor(variant, text, caret: text.utf16.count)
        let view = editor.view
        #expect(view.accessibilityValue() == text)
        for index in [0, 1, 12, 13, 18, 19] {
            let line = view.accessibilityLine(for: index)
            #expect(NSLocationInRange(index, view.accessibilityRange(forLine: line)), "index \(index) on line \(line)")
        }
        for word in [NSRange(location: 2, length: 5), NSRange(location: 14, length: 4)] {
            let frame = view.accessibilityFrame(for: word)
            let line = view.accessibilityFrame(for: view.accessibilityRange(forLine: view.accessibilityLine(for: word.location)))
            #expect(frame.width > 0 && frame.height > 0)
            #expect(line.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) outside its line \(line)")
        }
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func spellingFlagsSurviveRestyling(_ variant: TextKitVariant) {
        let text = "The **wrongg** day\nNext line\n"
        let editor = Editor(variant, text, caret: text.utf16.count)
        let view = editor.view
        let word = NSRange(location: 6, length: 6)
        view.checkText(in: NSRange(location: 0, length: text.utf16.count), types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
        let deadline = Date(timeIntervalSinceNow: 2)
        while editor.misspellings.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(editor.misspellings == [word])
        editor.place(8)
        #expect(editor.misspellings == [word], "after the reveal")
        editor.place(18)
        view.insertText("s", replacementRange: view.selectedRange())
        #expect(view.string == "The **wrongg** days\nNext line\n")
        #expect(editor.misspellings == [word], "after the restyle")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        #expect(editor.misspellings == [word], "after continuous checking catches up")
        editor.place(4)
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(view.selectedRange() == NSRange(location: 5, length: 0))
        #expect(editor.flagged == IndexSet(integersIn: 7..<13), "after typing at the span's start")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        #expect(editor.flagged == IndexSet(integersIn: 7..<13), "a second after typing at the span's start")
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func editsAtSpanEdgesLeaveTheCaretAfterTheEdit(_ variant: TextKitVariant) {
        let type = { (text: String) in { (view: EditorTextView) in view.insertText(text, replacementRange: view.selectedRange()) } }
        let cases: [(String, Int, (EditorTextView) -> Void, String, Int)] = [
            (Self.soft, 4, type("x"), "The x**soft** day", 5),
            (Self.soft, 4, { type("x")($0); type("y")($0) }, "The xy**soft** day", 6),
            (Self.soft, 6, { $0.deleteBackward(nil) }, "The *soft** day", 5),
            ("The soft** day", 4, type("**"), "The **soft** day", 6),
            ("# Title\n\(Self.soft)\n", 0, type("#"), "## Title\n\(Self.soft)\n", 1),
        ]
        for (text, caret, edit, edited, after) in cases {
            let editor = Editor(variant, text, caret: caret)
            edit(editor.view)
            #expect(editor.view.string == edited)
            #expect(editor.view.selectedRange() == NSRange(location: after, length: 0), "\(edited)")
            editor.expectTextKitUnchanged()
        }
    }

    @Test(arguments: TextKitVariant.allCases)
    func longTextStylesTheTopFirstAndTheRestBetweenEvents(_ variant: TextKitVariant) {
        let line = "\(Self.soft)\n"
        let editor = Editor(variant, String(repeating: line, count: 4000), caret: 0)
        let color = { (line: Int) in editor.view.textStorage!.attribute(.foregroundColor, at: line * 17 + 4, effectiveRange: nil) as? NSColor }
        #expect(color(0) == .clear && color(3999) != .clear)
        // Typing in unstyled text styles its paragraph at once.
        editor.place(3999 * 17 + 8)
        editor.view.insertText("x", replacementRange: editor.view.selectedRange())
        #expect(color(3999) == .tertiaryLabelColor)
        let deadline = Date(timeIntervalSinceNow: 10)
        while editor.view.styler.hasUnstyledText && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        #expect((0..<3999).allSatisfy { color($0) == .clear })
        #expect(editor.view.string == String(repeating: line, count: 3999) + "The **soxft** day\n")
        editor.expectTextKitUnchanged()
    }
}
