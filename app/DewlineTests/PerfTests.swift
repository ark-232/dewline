import AppKit
import Testing
@testable import Dewline

/// An editor in a window ordered front. The test host is not the active app, so the window is not key and
/// draws no caret.
@MainActor
private struct Editor {
    let variant: TextKitVariant
    let window: NSWindow
    let view: EditorTextView

    init(_ variant: TextKitVariant) {
        self.variant = variant
        let scrollView = EditorTextView.scrollView(variant: variant)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        display()
    }

    /// Displays and commits, then runs pending run loop work and repeats until the view's frame holds and nothing
    /// needs display. TextKit 1 lays out newly set text on the next pass; TextKit 2 corrects its height estimate.
    func display() {
        var frame: NSRect
        repeat {
            frame = view.frame
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(mode: .default, before: .distantPast)
        } while view.frame != frame || window.viewsNeedDisplay
    }

    func open(_ text: String) {
        view.string = text
        display()
        finishStyling()
    }

    /// Runs the run loop until the styler has styled the text it left for after the first display.
    func finishStyling() {
        let deadline = Date(timeIntervalSinceNow: 60)
        while view.styler.hasUnstyledText && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(!view.styler.hasUnstyledText)
    }

    /// Strong spans in the paragraphs from the start of the text to the bottom of the visible rect.
    var strongSpansShown: [SyntaxSpan] {
        let text = view.textStorage!.mutableString
        let visible = view.visibleRect
        let end = view.characterIndexForInsertion(at: NSPoint(x: visible.maxX, y: visible.maxY))
        var spans: [SyntaxSpan] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: end), options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
            spans += SpikeTokenizer.spans(in: text, line: line).filter { $0.kind == .strong }
        }
        return spans
    }

    /// Milliseconds from a key down sent through the window to the first committed display, and to the display
    /// settling. A typing pause follows.
    func press(_ keyCode: UInt16, _ characters: String) -> (first: Double, settled: Double) {
        let event = { (type: NSEvent.EventType) in
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )!
        }
        let down = event(.keyDown)
        let start = ContinuousClock.now
        window.sendEvent(down)
        window.displayIfNeeded()
        CATransaction.flush()
        let first = ContinuousClock.now - start
        display()
        let settled = ContinuousClock.now - start
        window.sendEvent(event(.keyUp))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        return (first / .milliseconds(1), settled / .milliseconds(1))
    }

    /// Puts the caret on screen and lets deferred work finish, including TextKit 1's background layout of the
    /// whole document, so measurements start from the state a reader reaches after a few seconds.
    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        display()
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        } while variant == .textKit1 && view.layoutManager!.firstUnlaidCharacterIndex() < view.textStorage!.length
    }

    /// The first strong span in a paragraph past the middle of the document.
    var middleSpan: SyntaxSpan {
        let text = view.textStorage!.mutableString
        let middle = text.paragraphRange(for: NSRange(location: text.length / 2, length: 0)).location
        var span: SyntaxSpan?
        text.enumerateSubstrings(in: NSRange(location: middle, length: text.length - middle), options: [.byParagraphs, .substringNotRequired]) { _, line, _, stop in
            span = SpikeTokenizer.spans(in: text, line: line).first { $0.kind == .strong }
            stop.pointee = ObjCBool(span != nil)
        }
        return span!
    }

    /// Empties the view first: a closed window's text system stays alive for a while, and TextKit 1 would go on laying
    /// out its text in the next measurement's run loop passes.
    func close() {
        #expect((view.textLayoutManager != nil) == (variant == .textKit2))
        view.string = ""
        window.close()
    }
}

private func milliseconds(_ body: () -> Void) -> Double {
    ContinuousClock().measure(body) / .milliseconds(1)
}

private func percentiles(_ samples: [Double]) -> [String: Double] {
    let sorted = samples.sorted()
    func rank(_ fraction: Double) -> Double {
        sorted[Int((fraction * Double(sorted.count)).rounded(.up)) - 1]
    }
    return ["p50": rank(0.5), "p95": rank(0.95), "p99": rank(0.99), "max": sorted.last!]
}

/// Runs only with `DEWLINE_PERF` set (`TEST_RUNNER_DEWLINE_PERF=1` through xcodebuild) and merges its numbers
/// into the JSON at `DEWLINE_PERF_OUT`, by variant. `scripts/perf.sh` runs it in a Release build. Key presses
/// count to their first committed display; opening and select all, which TextKit 1 finishes on later run loop
/// passes, count until the display settles. Opening also records when the styler has styled the text it left
/// for after the first display.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DEWLINE_PERF"] != nil))
struct PerfTests {
    static let documents = [("1MB", MarkdownCorpus.text(bytes: 1 << 20)), ("10MB", MarkdownCorpus.text(bytes: 10 << 20))]

    static func output() throws -> URL {
        URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DEWLINE_PERF_OUT"]))
    }

    func record(_ variant: TextKitVariant, _ metric: String, _ values: [String: Double]) throws {
        let url = try Self.output()
        var results = (try? JSONDecoder().decode([String: [String: [String: Double]]].self, from: Data(contentsOf: url))) ?? [:]
        results["\(variant)", default: [:]][metric] = values.mapValues { ($0 * 100).rounded() / 100 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: url)
    }

    @Test(arguments: TextKitVariant.allCases)
    func opening(_ variant: TextKitVariant) throws {
        for (size, text) in Self.documents {
            let editor = Editor(variant)
            let setText = milliseconds { editor.view.string = text }
            let display = milliseconds { editor.display() }
            let hidden = { (span: SyntaxSpan) in
                editor.view.textStorage!.attribute(.foregroundColor, at: span.range.location, effectiveRange: nil) as? NSColor == .clear
            }
            let shown = editor.strongSpansShown
            #expect(!shown.isEmpty && shown.allSatisfy(hidden), "the first display shows every span styled")
            let styling = milliseconds { editor.finishStyling() }
            #expect(hidden(editor.middleSpan))
            switch variant {
            case .textKit1:
                let used = editor.view.layoutManager!.usedRect(for: editor.view.textContainer!)
                #expect(used.maxY + editor.view.textContainerInset.height >= editor.view.visibleRect.maxY)
            case .textKit2:
                #expect(editor.view.textLayoutManager!.textViewportLayoutController.viewportRange?.isEmpty == false)
            }
            try record(variant, "open\(size)", ["ms": setText + display, "setTextMs": setText, "displayMs": display, "styledMs": setText + display + styling])
            editor.close()
            // scripts/perf.sh opens the same documents in the app.
            try text.write(to: Self.output().deletingLastPathComponent().appending(path: "\(size).md"), atomically: true, encoding: .utf8)
        }
    }

    @Test(arguments: TextKitVariant.allCases)
    func typing(_ variant: TextKitVariant) throws {
        for (size, text) in Self.documents {
            let editor = Editor(variant)
            editor.open(text)
            editor.place(editor.middleSpan.content.location + 1)
            let storage = editor.view.textStorage!
            let length = storage.length
            var samples: [Double] = []
            for _ in 0..<150 {
                samples.append(editor.press(0, "a").first)
                #expect(storage.length == length + 1 && !editor.view.hasMarkedText())
                samples.append(editor.press(51, "\u{7F}").first)
            }
            #expect(editor.view.string == text)
            try record(variant, "keystroke\(size)", percentiles(samples))
            editor.close()
        }
    }

    @Test(arguments: TextKitVariant.allCases)
    func revealing(_ variant: TextKitVariant) throws {
        let editor = Editor(variant)
        editor.open(Self.documents[0].1)
        let span = editor.middleSpan
        let outside = span.range.location - 1
        editor.place(outside)
        let storage = editor.view.textStorage!
        let revealed = { storage.attribute(.foregroundColor, at: span.range.location, effectiveRange: nil) as? NSColor == .tertiaryLabelColor }
        var moves: [Double] = []
        for _ in 0..<100 {
            moves.append(editor.press(124, "\u{F703}").first)
            #expect(revealed())
            moves.append(editor.press(123, "\u{F702}").first)
            #expect(!revealed())
        }
        var selectAll: [Double] = []
        var deselect: [Double] = []
        for _ in 0..<3 {
            selectAll.append(milliseconds { editor.view.selectAll(nil); editor.display() })
            #expect(revealed())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            deselect.append(milliseconds { editor.view.setSelectedRange(NSRange(location: outside, length: 0)); editor.display() })
            #expect(!revealed())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        try record(variant, "reveal", percentiles(moves).merging(["selectAll1MB": selectAll.sorted()[1], "deselect1MB": deselect.sorted()[1]]) { $1 })
        editor.close()
    }

    @Test(arguments: TextKitVariant.allCases)
    func scrolling(_ variant: TextKitVariant) throws {
        let editor = Editor(variant)
        editor.open(Self.documents[0].1)
        var first: [Double] = []
        var settled: [Double] = []
        for _ in 0..<200 {
            let top = editor.view.visibleRect.minY
            let step = editor.press(121, "\u{F72D}")
            first.append(step.first)
            settled.append(step.settled)
            #expect(editor.view.visibleRect.minY > top)
        }
        // TextKit 2 settles after correcting its height estimate for the newly laid out text.
        try record(variant, "scroll", percentiles(first).merging(["over8_3ms": Double(first.count { $0 > 8.3 })]) { $1 })
        try record(variant, "scrollSettled", percentiles(settled).merging(["over8_3ms": Double(settled.count { $0 > 8.3 })]) { $1 })
        editor.close()
    }
}
