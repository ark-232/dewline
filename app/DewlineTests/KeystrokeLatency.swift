import AppKit
import ObjectiveC
import Testing
@testable import Dewline

// What a keystroke costs, part by part, and what it does.
//
// A keystroke is a key down sent through a window that is never ordered in, the edited paragraph's layout, the
// window's layout and display passes and the commit, then the key up. `LatencyProbe` stamps the parse, attributes,
// reveal and caret; the test wraps the storage edit, TextKit 2's invalidation and layout, and NSFont's
// fontWithDescriptor:size: to stamp them too. Each part's own time counts toward one row of the keystroke budget, so
// the rows add up to the frame.
//
// `counts()` runs on every test run. `parts()` runs only with DEWLINE_LATENCY set (TEST_RUNNER_DEWLINE_LATENCY=1
// through xcodebuild) and prints each row's p50, p95 and p99 at 1 MB and 10 MB; with DEWLINE_LATENCY_OUT it writes
// every keystroke's rows there as JSON, and with DEWLINE_LATENCY_FRONT it brings the app and its window to the front,
// as scripts/perf.sh runs it.

/// The parts the test stamps; codes continue `LatencyProbe.Part`'s.
private enum TestPart: UInt16 {
    case keyDown = 100, paragraphLayout, windowLayout, display, commit, clock
    case replace, processEditing, invalidation, layout, font
}

/// The keystroke budget's rows.
private enum Row: String, CaseIterable {
    case keyDown, storageEdit, parse, attributes, reveal, invalidation, paragraphLayout, viewportLayout, caretAndDisplay, commit

    /// The row a part's own time counts toward; the phase is the part open outermost.
    init?(_ part: UInt16, phase: UInt16) {
        if let part = LatencyProbe.Part(rawValue: part) {
            switch part {
            case .parse: self = .parse
            case .attributes: self = .attributes
            case .reveal: self = .reveal
            case .caret: self = .caretAndDisplay
            }
            return
        }
        switch TestPart(rawValue: part) {
        case .keyDown?: self = .keyDown
        case .replace?, .processEditing?: self = .storageEdit
        case .invalidation?: self = .invalidation
        case .paragraphLayout?: self = .paragraphLayout
        case .layout?: self = phase == TestPart.windowLayout.rawValue ? .viewportLayout : .paragraphLayout
        case .windowLayout?: self = .viewportLayout
        case .display?: self = .caretAndDisplay
        case .commit?: self = .commit
        case .clock?, .font?, nil: return nil
        }
    }
}

private func begin(_ part: TestPart) {
    LatencyProbe.stamp(part.rawValue << 1)
}

private func end(_ part: TestPart) {
    LatencyProbe.stamp(part.rawValue << 1 | 1)
}

private let ticksPerMillisecond: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return 1e6 * Double(info.denom) / Double(info.numer)
}()

private func milliseconds(_ ticks: UInt64) -> Double {
    Double(ticks) / ticksPerMillisecond
}

private nonisolated(unsafe) var clockSink: UInt64 = 0

/// One keystroke from its stamps: each row's milliseconds, the frame from key down to commit, the clock probe, and
/// what it did.
private struct Keystroke {
    var rows: [Row: Double] = [:]
    var frame = 0.0
    /// Microseconds of a fixed integer workload run right after the frame, which track the clock the frame ran at.
    var clock = 0.0
    /// Text storage `processEditing` passes; `revealWrites` counts those the reveal makes.
    var storageEdits = 0
    var revealWrites = 0
    /// NSFont(descriptor:size:) calls made inside the editor's parts.
    var fonts = 0
    var restyles = 0
    var wellFormed = true

    init(_ stamps: [(code: UInt16, ticks: UInt64)]) {
        var stack: [(part: UInt16, begin: UInt64, children: UInt64)] = []
        for (code, ticks) in stamps {
            let part = code >> 1
            if part == TestPart.font.rawValue {
                if stack.contains(where: { LatencyProbe.Part(rawValue: $0.part) != nil }) { fonts += 1 }
                continue
            }
            if code & 1 == 0 {
                if part == TestPart.processEditing.rawValue {
                    storageEdits += 1
                    if stack.contains(where: { $0.part == LatencyProbe.Part.reveal.rawValue }) { revealWrites += 1 }
                }
                stack.append((part, ticks, 0))
                continue
            }
            guard let top = stack.popLast(), top.part == part, ticks >= top.begin else {
                wellFormed = false
                return
            }
            let inclusive = ticks - top.begin
            if let row = Row(part, phase: stack.first?.part ?? part) {
                rows[row, default: 0] += milliseconds(inclusive - min(top.children, inclusive))
            }
            if !stack.isEmpty {
                stack[stack.count - 1].children += inclusive
            } else if part == TestPart.clock.rawValue {
                clock = milliseconds(inclusive) * 1000
            } else {
                frame += milliseconds(inclusive)
            }
        }
        wellFormed = stack.isEmpty
    }
}

/// An Objective-C method swapped for a block that stamps a part around it, until `restore`.
private struct Wrap {
    let method: Method
    let original: IMP

    func restore() {
        method_setImplementation(method, original)
    }
}

/// Wraps the storage edit, TextKit 2's invalidation and layout, and NSFont's fontWithDescriptor:size:, which stamps
/// only its call.
@MainActor
private func wrapTextSystem() throws -> [Wrap] {
    typealias Plain = @convention(c) (AnyObject, Selector) -> Void
    typealias Object = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    typealias RangeObject = @convention(c) (AnyObject, Selector, NSRange, AnyObject) -> Void
    typealias Rect = @convention(c) (AnyObject, Selector, CGRect) -> Void
    typealias Editing = @convention(c) (AnyObject, Selector, AnyObject, UInt, NSRange, Int, NSRange) -> Void
    typealias Font = @convention(c) (AnyObject, Selector, AnyObject, CGFloat) -> AnyObject?
    func wrap(_ found: Method?, _ name: String, _ block: (Selector, IMP) -> Any) -> Wrap? {
        guard let method = found else {
            Issue.record("no method \(name)")
            return nil
        }
        let original = method_getImplementation(method)
        method_setImplementation(method, imp_implementationWithBlock(block(NSSelectorFromString(name), original)))
        return Wrap(method: method, original: original)
    }
    func instance(_ cls: AnyClass, _ name: String, _ block: (Selector, IMP) -> Any) -> Wrap? {
        wrap(class_getInstanceMethod(cls, NSSelectorFromString(name)), name, block)
    }
    func plain(_ part: TestPart) -> (Selector, IMP) -> Any {
        { selector, original in
            let call = unsafeBitCast(original, to: Plain.self)
            let block: @convention(block) (AnyObject) -> Void = { this in
                begin(part); call(this, selector); end(part)
            }
            return block
        }
    }
    func object(_ part: TestPart) -> (Selector, IMP) -> Any {
        { selector, original in
            let call = unsafeBitCast(original, to: Object.self)
            let block: @convention(block) (AnyObject, AnyObject) -> Void = { this, a in
                begin(part); call(this, selector, a); end(part)
            }
            return block
        }
    }
    func rangeObject(_ part: TestPart) -> (Selector, IMP) -> Any {
        { selector, original in
            let call = unsafeBitCast(original, to: RangeObject.self)
            let block: @convention(block) (AnyObject, NSRange, AnyObject) -> Void = { this, a, b in
                begin(part); call(this, selector, a, b); end(part)
            }
            return block
        }
    }
    // The class of the storage an editor's content storage makes.
    let storage: AnyClass = try #require(object_getClass(EditorTextView().textStorage))
    return [
        instance(storage, "replaceCharactersInRange:withString:", rangeObject(.replace)),
        instance(storage, "replaceCharactersInRange:withAttributedString:", rangeObject(.replace)),
        instance(storage, "processEditing", plain(.processEditing)),
        instance(NSTextContentStorage.self, "processEditingForTextStorage:edited:range:changeInLength:invalidatedRange:") { selector, original in
            let call = unsafeBitCast(original, to: Editing.self)
            let block: @convention(block) (AnyObject, AnyObject, UInt, NSRange, Int, NSRange) -> Void = { this, a, b, c, d, e in
                begin(.invalidation); call(this, selector, a, b, c, d, e); end(.invalidation)
            }
            return block
        },
        instance(NSTextLayoutManager.self, "invalidateLayoutForRange:", object(.invalidation)),
        instance(NSTextLayoutManager.self, "ensureLayoutForRange:", object(.layout)),
        instance(NSTextLayoutManager.self, "ensureLayoutForBounds:") { selector, original in
            let call = unsafeBitCast(original, to: Rect.self)
            let block: @convention(block) (AnyObject, CGRect) -> Void = { this, a in
                begin(.layout); call(this, selector, a); end(.layout)
            }
            return block
        },
        instance(NSTextViewportLayoutController.self, "layoutViewport", plain(.layout)),
        wrap(class_getClassMethod(NSFont.self, NSSelectorFromString("fontWithDescriptor:size:")), "fontWithDescriptor:size:") { selector, original in
            let call = unsafeBitCast(original, to: Font.self)
            let block: @convention(block) (AnyObject, AnyObject, CGFloat) -> AnyObject? = { this, descriptor, size in
                begin(.font)
                return call(this, selector, descriptor, size)
            }
            return block
        },
    ].compactMap { $0 }
}

/// Reports itself key, so the text view runs its caret as in the front window without being ordered in.
private final class KeyedWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// The editor in a window that is ordered in only when `front` is set.
@MainActor
private final class Editor {
    let window: NSWindow
    let view: EditorTextView

    init(front: Bool) throws {
        let scrollView = EditorTextView.scrollView()
        window = KeyedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = try #require(scrollView.documentView as? EditorTextView)
        if front {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(view)
    }

    /// Frames until the view's height holds and nothing needs display, at most 50.
    func settle() {
        var rounds = 0
        var frame: NSRect
        repeat {
            frame = view.frame
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(mode: .default, before: .distantPast)
            rounds += 1
        } while (view.frame != frame || window.viewsNeedDisplay) && rounds < 50
    }

    func open(_ text: String) {
        view.string = text
        settle()
        let deadline = Date(timeIntervalSinceNow: 120)
        while view.styler.hasUnstyledText && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Inside the first strong span, from `location` on, of a prose paragraph of 200 characters or more.
    func caret(from location: Int) throws -> Int {
        let text = try #require(view.textStorage).mutableString
        var span: SyntaxSpan?
        text.enumerateSubstrings(in: NSRange(location: location, length: text.length - location), options: [.byParagraphs, .substringNotRequired]) { _, line, _, stop in
            guard line.length >= 200, text.character(at: line.location) != 0x23 else { return }
            span = SpikeTokenizer.spans(in: text, line: line).first { $0.kind == .strong && $0.content.length > 2 }
            stop.pointee = ObjCBool(span != nil)
        }
        return try #require(span).content.location + 1
    }

    /// Puts the caret inside the first strong span of a prose paragraph past the middle of the text, coming from a key
    /// typed and deleted in the first such paragraph, as typing moves on through a document. Returns the caret.
    func placeMiddle() throws -> Int {
        place(try caret(from: 0))
        for typing in [true, false] { _ = try keystroke(typing: typing, pause: 0) }
        let text = try #require(view.textStorage).mutableString
        let caret = try caret(from: text.paragraphRange(for: NSRange(location: text.length / 2, length: 0)).location)
        place(caret)
        return caret
    }

    /// Puts the caret on screen and lets deferred work finish.
    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        settle()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        settle()
    }

    func event(_ type: NSEvent.EventType, _ keyCode: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    /// Types "a", or deletes it: the key down, the layout of the caret's paragraph, the window's layout and display
    /// passes and the commit, stamped, then the clock probe, the key up and the pause.
    func keystroke(typing: Bool, pause: TimeInterval) throws -> Keystroke {
        let down = try event(.keyDown, typing ? 0 : 51, typing ? "a" : "\u{7F}")
        let up = try event(.keyUp, typing ? 0 : 51, typing ? "a" : "\u{7F}")
        let layout = try #require(view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let restyles = view.styler.restyles
        LatencyProbe.stamps.removeAll(keepingCapacity: true)
        LatencyProbe.enabled = true
        begin(.keyDown)
        window.sendEvent(down)
        end(.keyDown)
        let caret = content.location(content.documentRange.location, offsetBy: view.selectedRange().location)
        begin(.paragraphLayout)
        if let caret { layout.ensureLayout(for: NSTextRange(location: caret)) }
        end(.paragraphLayout)
        begin(.windowLayout)
        window.layoutIfNeeded()
        end(.windowLayout)
        begin(.display)
        window.displayIfNeeded()
        end(.display)
        begin(.commit)
        CATransaction.flush()
        end(.commit)
        begin(.clock)
        var x: UInt64 = 1
        for i in 0..<20_000 { x = x &* 6_364_136_223_846_793_005 &+ UInt64(i) }
        clockSink = x
        end(.clock)
        LatencyProbe.enabled = false
        var keystroke = Keystroke(LatencyProbe.stamps)
        keystroke.restyles = view.styler.restyles - restyles
        window.sendEvent(up)
        if pause > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: pause)) }
        return keystroke
    }

    /// Empties the view first: a closed window's text system stays alive for a while, still holding the text.
    func close() {
        view.string = ""
        window.close()
    }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[max(Int((fraction * Double(sorted.count)).rounded(.up)) - 1, 0)]
}

@MainActor
@Suite(.serialized)
struct KeystrokeLatency {
    /// Typing in the middle of 1 MB, each keystroke restyles once, edits the storage once, builds no font from a
    /// descriptor and leaves the reveal nothing to write.
    @Test func counts() throws {
        let wraps = try wrapTextSystem()
        defer { wraps.forEach { $0.restore() } }
        let editor = try Editor(front: false)
        defer { editor.close() }
        editor.open(MarkdownCorpus.text(bytes: 1 << 20))
        let caret = try editor.placeMiddle()
        let keystrokes = try (0..<8).map { try editor.keystroke(typing: $0 % 2 == 0, pause: 0) }
        #expect(editor.view.selectedRange() == NSRange(location: caret, length: 0))
        #expect(keystrokes.map(\.wellFormed) == Array(repeating: true, count: 8))
        #expect(keystrokes.map(\.restyles) == Array(repeating: 1, count: 8))
        withKnownIssue("A1: AppKit widens the edited range to the paragraph, the restyle takes its end for the caret and hides the span under the caret, and the reveal shows it again in a second storage edit") {
            #expect(keystrokes.map(\.storageEdits) == Array(repeating: 1, count: 8))
            #expect(keystrokes.map(\.revealWrites) == Array(repeating: 0, count: 8))
        }
        withKnownIssue("A2: each restyle builds the body font from its descriptor") {
            #expect(keystrokes.map(\.fonts) == Array(repeating: 0, count: 8))
        }
        print("KeystrokeLatency counts: storage edits \(keystrokes.map(\.storageEdits)), restyles \(keystrokes.map(\.restyles)), fonts \(keystrokes.map(\.fonts)), reveal writes \(keystrokes.map(\.revealWrites))")
    }

    /// Off, a stamp is a load and a branch and records nothing: its time, less an empty loop's, is a few nanoseconds.
    @Test func stampOff() {
        LatencyProbe.stamps.removeAll()
        #expect(!LatencyProbe.enabled)
        let passes = 1_000_000
        var stamped = Double.infinity
        var bare = Double.infinity
        for _ in 0..<5 {
            var start = mach_absolute_time()
            for _ in 0..<passes {
                LatencyProbe.begin(.parse)
                LatencyProbe.end(.parse)
            }
            stamped = min(stamped, milliseconds(mach_absolute_time() - start))
            start = mach_absolute_time()
            for pass in 0..<passes { clockSink &+= UInt64(pass) }
            bare = min(bare, milliseconds(mach_absolute_time() - start))
        }
        let nanoseconds = (stamped - bare) * 1e6 / Double(2 * passes)
        print(String(format: "KeystrokeLatency stamp off: %.2f ns, loop pass %.2f ns", nanoseconds, bare * 1e6 / Double(passes)))
        #expect(LatencyProbe.stamps.isEmpty)
        #expect(nanoseconds < 10, "a stamp with the probe off costs \(nanoseconds) ns")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEWLINE_LATENCY"] != nil))
    func parts() throws {
        let environment = ProcessInfo.processInfo.environment
        let front = environment["DEWLINE_LATENCY_FRONT"] != nil
        let wraps = try wrapTextSystem()
        defer { wraps.forEach { $0.restore() } }
        // A test host that is not in front may be napped.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Keystroke latency")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // The first window a process makes draws its text layers into half-float backing stores, several times slower
        // than any later window's; a throwaway first window keeps the measured ones on the later path.
        try Editor(front: false).close()
        var cells: [String: [String: [Double]]] = [:]
        var clocks: [Double] = []
        for megabytes in [1, 10] {
            let text = MarkdownCorpus.text(bytes: megabytes << 20)
            let editor = try Editor(front: front)
            editor.open(text)
            _ = try editor.placeMiddle()
            var keystrokes: [Keystroke] = []
            for index in 0..<406 {
                let keystroke = try editor.keystroke(typing: index % 2 == 0, pause: 0.05)
                // The first few warm up.
                if index >= 6 && keystroke.wellFormed { keystrokes.append(keystroke) }
            }
            #expect(editor.view.string == text)
            #expect(keystrokes.count == 400)
            var cell = ["frame": keystrokes.map(\.frame)]
            for row in Row.allCases {
                cell[row.rawValue] = keystrokes.map { $0.rows[row] ?? 0 }
            }
            cells["\(megabytes)MB"] = cell.mapValues { $0.map { ($0 * 10000).rounded() / 10000 } }
            clocks += keystrokes.map(\.clock)
            editor.close()
        }
        let clock = (percentile(clocks, 0.5) * 100).rounded() / 100
        var report = ["KeystrokeLatency, ms p50 / p95 / p99; clock probe \(clock) µs; \(NSApp.isActive ? "in front" : "not in front")"]
        for key in ["frame"] + Row.allCases.map(\.rawValue) {
            let values = ["1MB", "10MB"].map { cells[$0]?[key] ?? [] }.map { values in
                [0.5, 0.95, 0.99].map { String(format: "%.2f", percentile(values, $0)) }.joined(separator: " / ")
            }
            report.append(key.padding(toLength: 16, withPad: " ", startingAt: 0) + " 1 MB " + values[0] + "   10 MB " + values[1])
        }
        print(report.joined(separator: "\n"))
        if let out = environment["DEWLINE_LATENCY_OUT"] {
            let result: [String: Any] = ["clockUs": clock, "frontmost": NSApp.isActive, "cells": cells]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        }
    }
}
