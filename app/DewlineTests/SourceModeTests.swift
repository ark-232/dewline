import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    /// The anchor can hold no closer than one device pixel: 0.5 pt on a Retina display, 1 pt at 1x.
    var pixel: CGFloat { 1 / window.backingScaleFactor }

    init(_ text: String, caret: Int) {
        let scrollView = EditorTextView.scrollView()
        // DEWLINE_TEST_SCALE=1 (TEST_RUNNER_DEWLINE_TEST_SCALE=1 through xcodebuild) puts the window on a 1x screen, as on
        // CI, when the Mac has one.
        let scale = ProcessInfo.processInfo.environment["DEWLINE_TEST_SCALE"].flatMap(Double.init)
        let screen = NSScreen.screens.first { $0.backingScaleFactor == scale }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    func rect(_ location: Int, _ length: Int) -> NSRect {
        view.firstRect(forCharacterRange: NSRange(location: location, length: length), actualRange: nil)
    }

    func expectTextKitUnchanged() {
        #expect(view.textLayoutManager != nil)
    }

    /// One frame: the window's layout pass, then its display pass.
    func display() {
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    /// A frame and a pause, in which the styler finishes the text it left for after the first display.
    func settle() {
        display()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    }

    /// The line box `firstRect` reports for the character at `index`, in the view's coordinates.
    func line(_ index: Int) -> NSRect {
        view.convert(window.convertFromScreen(rect(index, 0)), from: nil)
    }

    /// Where the anchor's baseline sits below the top of the visible rect, checked against its line box.
    func position(of anchor: Int) throws -> CGFloat {
        let baseline = try #require(view.baseline(at: anchor))
        let line = line(anchor)
        #expect(line.minY < baseline && baseline <= line.maxY, "baseline \(baseline) outside its line \(line)")
        return baseline - view.visibleRect.minY
    }
}

@MainActor
@Suite(.serialized)
struct SourceModeTests {
    static let sample = "# Title\n\nThe **soft** day, *quiet* `code` ~~gone~~ [link](https://example.com) _too_.\n"
    static let long = (1...120).map {
        "## Part \($0)\n\nThe **soft** day began with *quiet* rain, and `code` sat ~~gone~~ beside a [link](https://example.com/\($0)) that waited long enough to wrap.\n"
    }.joined(separator: "\n")

    @Test func togglingKeepsStringSelectionAndUndo() {
        let editor = Editor(Self.sample, caret: 17)
        let view = editor.view
        view.insertText("x", replacementRange: view.selectedRange())
        view.styler.undoManager.endUndoGrouping()
        let edited = view.string
        let selection = NSRange(location: 14, length: 6)
        view.setSelectedRange(selection)
        editor.display()
        for toggle in 1...10 {
            view.toggleSource(nil)
            editor.display()
            #expect(view.styler.showsSource == !toggle.isMultiple(of: 2))
            #expect(view.string == edited)
            #expect(view.selectedRanges.map(\.rangeValue) == [selection])
        }
        let undo = view.styler.undoManager
        #expect(undo.canUndo && !undo.canRedo)
        editor.window.tryToPerform(Selector(("undo:")), with: nil)
        #expect(view.string == Self.sample)
        #expect(!undo.canUndo)
        editor.expectTextKitUnchanged()
    }

    @Test func typingAndUndoWorkInSource() {
        let editor = Editor(Self.sample, caret: 17)
        let view = editor.view
        view.toggleSource(nil)
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(view.string == Self.sample.replacingOccurrences(of: "soft", with: "soxft"))
        let font = view.textStorage!.attribute(.font, at: 17, effectiveRange: nil) as! NSFont
        #expect(font.isFixedPitch && font.fontDescriptor.symbolicTraits.contains(.bold))
        view.styler.undoManager.endUndoGrouping()
        editor.window.tryToPerform(Selector(("undo:")), with: nil)
        #expect(view.string == Self.sample)
        #expect(editor.rect(13, 2).width > 2)
        editor.expectTextKitUnchanged()
    }

    @Test func sourceShowsEveryMarker() {
        let text = NSString(string: Self.sample)
        let editor = Editor(Self.sample, caret: text.length)
        editor.view.toggleSource(nil)
        let storage = editor.view.textStorage!
        let size = MarkdownStyler.code(matching: MarkdownStyler.bodyFont).pointSize
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            let font = value as! NSFont
            #expect(font.isFixedPitch && font.pointSize == size, "\(font) at \(run)")
        }
        let markers = editor.view.styler.map.blocks(in: NSRange(location: 0, length: text.length))
            .flatMap { block in block.spans.flatMap { $0.shifted(by: block.range.location).markers } }
        #expect(markers.count == 13)
        for marker in markers {
            let width = editor.rect(marker.location, marker.length).width
            #expect(width > 2, "marker at \(marker.location) is \(width) pt wide")
        }
        editor.expectTextKitUnchanged()
    }

    @Test func toggleWaitsForTheComposition() {
        let editor = Editor("\(HideSyntaxTests.soft)\n", caret: 8)
        let view = editor.view
        let storage = view.textStorage!
        let none = NSRange(location: NSNotFound, length: 0)
        let fixedPitch = { (index: Int) in (storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont).isFixedPitch }
        view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        let styled = (0..<18).map { storage.attributes(at: $0, effectiveRange: nil) as NSDictionary }
        view.toggleSource(nil)
        #expect(!view.styler.showsSource)
        #expect((0..<18).map { storage.attributes(at: $0, effectiveRange: nil) as NSDictionary } == styled)
        view.insertText("â", replacementRange: view.markedRange())
        #expect(view.string == "The **soâft** day\n")
        #expect(view.styler.showsSource)
        #expect(fixedPitch(0) && fixedPitch(8))
        #expect((view.typingAttributes[.font] as! NSFont).isFixedPitch)
        view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(fixedPitch(view.markedRange().location))
        view.insertText("x", replacementRange: view.markedRange())
        #expect(view.string == "The **soâxft** day\n")
        #expect(view.styler.showsSource)
        view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        view.toggleSource(nil)
        view.toggleSource(nil)
        view.unmarkText()
        #expect(view.string == "The **soâxaft** day\n")
        #expect(view.styler.showsSource, "two requests during one composition cancel out")
        view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        view.toggleSource(nil)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)
        #expect(view.string == "The **soâxaft** day\n")
        #expect(!view.styler.showsSource, "a cancelled composition still lets the waiting toggle run")
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: [0.5, 0.97])
    func theCaretLineStaysPut(at fraction: Double) throws {
        let start = Int(Double(Self.long.utf16.count) * fraction)
        let caret = (Self.long as NSString).range(of: "rain", options: [], range: NSRange(location: start, length: 300)).location
        for lineHeight in [22.0, 24.5] {
            let editor = Editor(Self.long, caret: caret)
            let view = editor.view
            view.styler.sourceLineHeight = lineHeight
            view.scrollRangeToVisible(NSRange(location: caret, length: 0))
            editor.settle()
            view.scroll(NSPoint(x: 0, y: view.visibleRect.minY - 123.3))
            editor.display()
            let before = try editor.position(of: caret)
            for _ in 1...4 {
                view.toggleSource(nil)
                editor.display()
                let after = try editor.position(of: caret)
                #expect(abs(after - before) <= editor.pixel, "\(lineHeight) pt lines: moved from \(before) to \(after), pixel \(editor.pixel)")
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
                let settled = try editor.position(of: caret)
                #expect(abs(settled - after) <= 0.01, "\(lineHeight) pt lines: settled from \(after) to \(settled)")
            }
            #expect(view.selectedRange() == NSRange(location: caret, length: 0))
            editor.expectTextKitUnchanged()
        }
    }

    @Test(arguments: [false, true])
    func theFirstVisibleLineStaysPutWhenTheCaretIsAway(below: Bool) throws {
        let caret = below ? Self.long.utf16.count - 1 : 0
        for lineHeight in [22.0, 24.5] {
            let editor = Editor(Self.long, caret: caret)
            let view = editor.view
            view.styler.sourceLineHeight = lineHeight
            view.scrollRangeToVisible(NSRange(location: Self.long.utf16.count / 2, length: 0))
            editor.settle()
            let top = try #require(view.baseline(at: view.characterIndexForInsertion(at: view.visibleRect.origin)))
            view.scroll(NSPoint(x: 0, y: top - 5.3))
            editor.display()
            for _ in 1...4 {
                let anchor = view.characterIndexForInsertion(at: view.visibleRect.origin)
                let before = try editor.position(of: anchor)
                view.toggleSource(nil)
                editor.display()
                let after = try editor.position(of: anchor)
                #expect(abs(after - before) <= editor.pixel, "\(lineHeight) pt lines: line at \(anchor) moved from \(before) to \(after), pixel \(editor.pixel)")
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
                let settled = try editor.position(of: anchor)
                #expect(abs(settled - after) <= 0.01, "\(lineHeight) pt lines: settled from \(after) to \(settled)")
            }
            #expect(view.selectedRange() == NSRange(location: caret, length: 0))
            editor.expectTextKitUnchanged()
        }
    }

    @Test func atProsePitchSourceBaselinesSitWithinAPointOfProse() throws {
        let text = "Plain words here.\nMore plain words.\n"
        let editor = Editor(text, caret: text.utf16.count)
        editor.view.styler.sourceLineHeight = 24.5
        let lines = [0, 18]
        let live = try lines.map { try #require(editor.view.baseline(at: $0)) - editor.line($0).minY }
        editor.view.toggleSource(nil)
        let source = try lines.map { try #require(editor.view.baseline(at: $0)) - editor.line($0).minY }
        for (prose, mono) in zip(live, source) {
            #expect(abs(prose - mono) <= 1, "baseline \(mono) pt into a Source line, \(prose) pt into a Live line")
        }
        editor.expectTextKitUnchanged()
    }

    @Test func aKeystrokeRightAfterAToggleLandsAndTheLineHolds() throws {
        let heading = (Self.long as NSString).range(of: "## Part 60\n")
        var caret = NSMaxRange(heading) - 1
        let editor = Editor(Self.long, caret: caret)
        let view = editor.view
        view.scrollRangeToVisible(NSRange(location: caret, length: 0))
        editor.settle()
        let subviews = view.subviews.count
        for delay in stride(from: 0.0, through: 0.1, by: 0.02) {
            let before = try editor.position(of: caret)
            view.toggleSource(nil)
            #expect(view.subviews.count == subviews + 1, "no snapshot over the viewport")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: delay))
            view.insertText("x", replacementRange: view.selectedRange())
            caret += 1
            #expect((view.string as NSString).substring(with: NSRange(location: caret - 1, length: 1)) == "x")
            #expect(view.subviews.count == subviews, "the fading snapshot stays over the typed text")
            editor.display()
            let after = try editor.position(of: caret)
            #expect(abs(after - before) <= editor.pixel, "\(Int(delay * 1000)) ms: moved from \(before) to \(after), pixel \(editor.pixel)")
        }
        editor.expectTextKitUnchanged()
    }

    @Test func theFirstFrameShowsTheNewModeOnScreen() throws {
        let caret = (Self.long as NSString).range(of: "rain", options: [], range: NSRange(location: Self.long.utf16.count / 2, length: 300)).location
        let editor = Editor(Self.long, caret: caret)
        let view = editor.view
        view.scrollRangeToVisible(NSRange(location: caret, length: 0))
        editor.settle()
        let before = try editor.position(of: caret)
        var onScreen: [NSFont] = []
        var caretLine: CGFloat?
        let witness = Witness(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        witness.drawn = {
            let visible = view.visibleRect
            let first = view.characterIndexForInsertion(at: NSPoint(x: visible.minX, y: visible.minY + 1))
            let last = view.characterIndexForInsertion(at: NSPoint(x: visible.maxX, y: visible.maxY - 1))
            onScreen = stride(from: first, to: last, by: 37).map { view.textStorage!.attribute(.font, at: $0, effectiveRange: nil) as! NSFont }
            caretLine = view.baseline(at: caret).map { $0 - visible.minY }
        }
        editor.window.contentView?.addSubview(witness)
        editor.display()
        witness.needsDisplay = true
        view.toggleSource(nil)
        #expect(!onScreen.isEmpty)
        #expect(onScreen.allSatisfy { $0.isFixedPitch }, "the first frame after the toggle still shows prose")
        let first = try #require(caretLine)
        #expect(abs(first - before) <= 0.5, "the first frame puts the caret line at \(first), not \(before)")
        editor.expectTextKitUnchanged()
    }

    @Test func anEmptyDocumentTogglesAndTakesText() {
        let editor = Editor("", caret: 0)
        let view = editor.view
        view.toggleSource(nil)
        editor.display()
        view.insertText("# a", replacementRange: view.selectedRange())
        let font = view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        #expect(view.styler.showsSource && font.isFixedPitch)
        view.toggleSource(nil)
        #expect(!view.styler.showsSource && view.string == "# a")
        editor.expectTextKitUnchanged()
    }

    @Test func findWorksAcrossToggles() {
        let text = HideSyntaxTests.soft + "\n" + String(repeating: "Plain filler words.\n", count: 80) + "Another **soft** word\n"
        let editor = Editor(text, caret: 0)
        let view = editor.view
        let pasteboard = NSPasteboard(name: .find)
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        func find(_ action: NSTextFinder.Action) {
            let item = NSMenuItem()
            item.tag = action.rawValue
            view.performFindPanelAction(item)
        }
        let first = NSRange(location: 6, length: 4)
        let second = (text as NSString).range(of: "soft", options: .backwards)
        view.setSelectedRange(first)
        find(.setSearchString)
        view.toggleSource(nil)
        find(.nextMatch)
        #expect(view.selectedRange() == second)
        editor.display()
        let match = view.convert(editor.window.convertFromScreen(editor.rect(second.location, second.length)), from: nil)
        #expect(match.width > 0 && view.visibleRect.contains(match), "\(match) outside \(view.visibleRect)")
        view.toggleSource(nil)
        find(.nextMatch)
        #expect(view.selectedRange() == first)
        editor.expectTextKitUnchanged()
    }
}

/// Runs `drawn` when the window draws it, to see what the window shows in that frame.
final class Witness: NSView {
    var drawn: () -> Void = {}

    override func draw(_ dirtyRect: NSRect) {
        drawn()
    }
}
