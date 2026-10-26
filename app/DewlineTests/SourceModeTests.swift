import AppKit
import Testing
@testable import Dewline

extension Editor {
    /// One frame: the window's layout pass, then its display pass.
    func display() {
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    /// Where the anchor's baseline sits below the top of the visible rect, checked against the line `firstRect` reports.
    func position(of anchor: Int) throws -> CGFloat {
        let baseline = try #require(view.baseline(at: anchor))
        let line = view.convert(window.convertFromScreen(rect(anchor, 0)), from: nil)
        #expect(line.minY < baseline && baseline <= line.maxY, "baseline \(baseline) outside its line \(line) visible \(view.visibleRect)")
        return baseline - view.visibleRect.minY
    }
}

@MainActor
struct SourceModeTests {
    static let sample = "# Title\n\nThe **soft** day, *quiet* `code` ~~gone~~ [link](https://example.com) _too_.\n"
    static let long = (1...120).map {
        "## Part \($0)\n\nThe **soft** day began with *quiet* rain, and `code` sat ~~gone~~ beside a [link](https://example.com/\($0)) that waited long enough to wrap.\n"
    }.joined(separator: "\n")

    @Test(arguments: TextKitVariant.allCases)
    func togglingKeepsStringSelectionAndUndo(_ variant: TextKitVariant) {
        let editor = Editor(variant, Self.sample, caret: 17)
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

    @Test(arguments: TextKitVariant.allCases)
    func typingAndUndoWorkInSource(_ variant: TextKitVariant) {
        let editor = Editor(variant, Self.sample, caret: 17)
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

    @Test(arguments: TextKitVariant.allCases)
    func sourceShowsEveryMarker(_ variant: TextKitVariant) {
        let text = NSString(string: Self.sample)
        let editor = Editor(variant, Self.sample, caret: text.length)
        editor.view.toggleSource(nil)
        let storage = editor.view.textStorage!
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            let font = value as! NSFont
            #expect(font.isFixedPitch && font.pointSize == 15, "\(font) at \(run)")
        }
        var markers: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
            markers += SpikeTokenizer.spans(in: text, line: line).flatMap(\.markers)
        }
        #expect(markers.count == 13)
        for marker in markers {
            let width = editor.rect(marker.location, marker.length).width
            #expect(width > 2, "marker at \(marker.location) is \(width) pt wide")
        }
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func toggleWaitsForTheComposition(_ variant: TextKitVariant) {
        let editor = Editor(variant, "\(HideSyntaxTests.soft)\n", caret: 8)
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
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases, [0.5, 0.97])
    func theCaretLineStaysPut(_ variant: TextKitVariant, at fraction: Double) throws {
        let start = Int(Double(Self.long.utf16.count) * fraction)
        let caret = (Self.long as NSString).range(of: "rain", options: [], range: NSRange(location: start, length: 300)).location
        let editor = Editor(variant, Self.long, caret: caret)
        let view = editor.view
        view.scrollRangeToVisible(NSRange(location: caret, length: 0))
        editor.display()
        view.scroll(NSPoint(x: 0, y: view.visibleRect.minY - 123.3))
        editor.display()
        var before = try editor.position(of: caret)
        for _ in 1...4 {
            view.toggleSource(nil)
            editor.display()
            let after = try editor.position(of: caret)
            #expect(abs(after - before) <= 1, "moved from \(before) to \(after)")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            let settled = try editor.position(of: caret)
            #expect(abs(settled - after) <= 0.01, "settled from \(after) to \(settled)")
            before = after
        }
        #expect(view.selectedRange() == NSRange(location: caret, length: 0))
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func theFirstVisibleLineStaysPutWhenTheCaretIsAway(_ variant: TextKitVariant) throws {
        let editor = Editor(variant, Self.long, caret: 0)
        let view = editor.view
        view.scrollRangeToVisible(NSRange(location: Self.long.utf16.count / 2, length: 0))
        editor.display()
        let top = try #require(view.baseline(at: view.characterIndexForInsertion(at: view.visibleRect.origin)))
        view.scroll(NSPoint(x: 0, y: top - 5.3))
        editor.display()
        for _ in 1...4 {
            let anchor = view.characterIndexForInsertion(at: view.visibleRect.origin)
            let before = try editor.position(of: anchor)
            view.toggleSource(nil)
            editor.display()
            let after = try editor.position(of: anchor)
            #expect(abs(after - before) <= 1, "line at \(anchor) moved from \(before) to \(after)")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            let settled = try editor.position(of: anchor)
            #expect(abs(settled - after) <= 0.01, "settled from \(after) to \(settled) visible \(view.visibleRect) frame \(view.frame)")
        }
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func findWorksAcrossToggles(_ variant: TextKitVariant) {
        let text = HideSyntaxTests.soft + "\n" + String(repeating: "Plain filler words.\n", count: 80) + "Another **soft** word\n"
        let editor = Editor(variant, text, caret: 0)
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
