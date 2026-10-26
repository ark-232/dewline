import AppKit
import Testing
@testable import Dewline

/// What the Live/Source switch costs each TextKit stack. Runs only with `DEWLINE_PERF` set (`TEST_RUNNER_DEWLINE_PERF=1` in
/// xcodebuild's environment), in a Release build with `ENABLE_TESTABILITY=YES`. The test host cannot become the active app, so
/// timing starts where Option-Command-U lands: the menu's action.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DEWLINE_PERF"] != nil))
struct SourceModeMeasurements {
    static func milliseconds(_ duration: Duration) -> Double {
        duration / .milliseconds(1)
    }

    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
    }

    /// One frame: the window's layout and display passes, committed to the window server.
    static func frame(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }

    /// A front window on the corpus with the caret mid-document and on screen, after TextKit 1 finishes its background layout.
    static func editor(_ variant: TextKitVariant, bytes: Int, lineHeight: CGFloat = 22) throws -> (NSWindow, EditorTextView, caret: Int) {
        let scrollView = EditorTextView.scrollView(variant: variant)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let view = try #require(scrollView.documentView as? EditorTextView)
        view.styler.sourceLineHeight = lineHeight
        view.string = MarkdownCorpus.text(bytes: bytes)
        window.orderFront(nil)
        window.makeFirstResponder(view)
        let storage = try #require(view.textStorage)
        let caret = storage.mutableString.range(of: " ", range: NSRange(location: storage.length / 2, length: 2000)).location
        view.setSelectedRange(NSRange(location: caret, length: 0))
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        } while view.textLayoutManager == nil && (view.layoutManager?.firstUnlaidCharacterIndex() ?? 0) < storage.length
        // TextKit 1 sizes the view only as far as it has laid out, so a scroll made during its background layout can stop short.
        view.scrollRangeToVisible(NSRange(location: caret, length: 0))
        frame(window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let line = try #require(view.baseline(at: caret)) - view.visibleRect.minY
        try #require(line > 0 && line < view.visibleRect.height, "the caret line sits \(line) pt below the top of the visible rect")
        return (window, view, caret)
    }

    static func layOutEverything(_ view: EditorTextView) {
        if let layout = view.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        } else if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
        }
    }

    /// Lines and height of every paragraph, from TextKit 2's layout fragments.
    static func paragraphs(_ view: EditorTextView) -> [(lines: Int, height: CGFloat)] {
        var paragraphs: [(lines: Int, height: CGFloat)] = []
        if let layout = view.textLayoutManager {
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                paragraphs.append((fragment.textLineFragments.count, fragment.layoutFragmentFrame.height))
                return true
            }
        }
        return paragraphs
    }

    /// Sends the toggle and draws a frame: milliseconds to the committed fade and to the end, and how far the caret line
    /// moved in the toggle's first frame and once it is done.
    static func press(_ window: NSWindow, _ view: EditorTextView, caret: Int, offset: CGFloat) throws -> (fade: Double, done: Double, first: Double, drift: Double) {
        var first: CGFloat?
        let witness = Witness(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        witness.drawn = {
            if first == nil { first = view.baseline(at: caret).map { $0 - view.visibleRect.minY - offset } }
        }
        window.contentView?.addSubview(witness)
        defer { witness.removeFromSuperview() }
        let start = ContinuousClock.now
        NSApp.sendAction(#selector(EditorTextView.toggleSource(_:)), to: view, from: nil)
        frame(window)
        let done = ContinuousClock.now
        let fade = try #require(view.fadeStarted)
        let drift = try #require(view.baseline(at: caret)) - view.visibleRect.minY - offset
        return (milliseconds(fade - start), milliseconds(done - start), try #require(first), drift)
    }

    // TextKit 1 at 10 MB times the styler's whole-document restyle, which the hot-paths lane measures, not the toggle.
    @Test(arguments: [(TextKitVariant.textKit1, 1_000_000, 20), (.textKit2, 1_000_000, 20), (.textKit2, 10_000_000, 10)])
    func toggle(_ variant: TextKitVariant, bytes: Int, toggles: Int) throws {
        let unopened = Self.footprint()
        let (window, view, caret) = try Self.editor(variant, bytes: bytes)
        defer { window.close() }
        let opened = Self.footprint()
        let offset = try #require(view.baseline(at: caret)) - view.visibleRect.minY
        var fades: [[Double]] = [[], []]
        var dones: [[Double]] = [[], []]
        var first: [Double] = []
        var drift: [Double] = []
        var settled: [Double] = []
        for toggle in 0..<toggles {
            // Each keystroke in the app drains its own autorelease pool.
            try autoreleasepool {
                let pressed = try Self.press(window, view, caret: caret, offset: offset)
                #expect(view.styler.showsSource == toggle.isMultiple(of: 2))
                fades[toggle % 2].append(pressed.fade)
                dones[toggle % 2].append(pressed.done)
                first.append(pressed.first)
                drift.append(pressed.drift)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
                settled.append(try #require(view.baseline(at: caret)) - view.visibleRect.minY - offset)
            }
        }
        let toggled = Self.footprint()

        var full: [String] = []
        for _ in 0..<2 {
            let start = ContinuousClock.now
            _ = try Self.press(window, view, caret: caret, offset: offset)
            Self.layOutEverything(view)
            let laidOut = Self.milliseconds(ContinuousClock.now - start)
            Self.frame(window)
            let moved = try #require(view.baseline(at: caret)) - view.visibleRect.minY - offset
            full.append(String(format: "%.0f ms, after which the caret line sits %.1f pt off", laidOut, moved))
        }

        let points = { (values: [Double]) in values.map { String(format: "%.2f", $0) }.joined(separator: " ") }
        let format = { (values: [Double]) in
            String(format: "p50 %.1f, p95 %.1f, max %.1f ms", Self.percentile(values, 0.5), Self.percentile(values, 0.95), Self.percentile(values, 1))
                + " (in order: " + values.map { String(format: "%.0f", $0) }.joined(separator: " ") + ")"
        }
        print(
            """
            SOURCE-MODE \(variant) \(bytes / 1_000_000) MB
              fade starts, Live to Source: \(format(fades[0])); Source to Live: \(format(fades[1]))
              toggle done, Live to Source: \(format(dones[0])); Source to Live: \(format(dones[1]))
              caret line per toggle, pt off: first frame \(points(first)); toggle done \(points(drift)); after 0.4 s \(points(settled))
              full layout after a toggle, Live to Source: \(full[0]); Source to Live: \(full[1])
              phys_footprint: \(Int(unopened)) MB before opening, \(Int(opened)) MB open, \(Int(toggled)) MB after \(toggles) toggles
            """
        )
    }

    @Test(arguments: [22.0, 24.5])
    func pitch(_ lineHeight: Double) throws {
        var report: [String] = []
        for variant in TextKitVariant.allCases {
            let (window, view, caret) = try Self.editor(variant, bytes: 1_000_000, lineHeight: lineHeight)
            defer { window.close() }
            let offset = try #require(view.baseline(at: caret)) - view.visibleRect.minY
            var drift = 0.0
            for _ in 0..<10 {
                try autoreleasepool {
                    drift = max(drift, abs(try Self.press(window, view, caret: caret, offset: offset).drift))
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
                }
            }
            report.append("\(variant) caret line drift max \(String(format: "%.2f", drift)) pt")
            if variant == .textKit2 {
                let live = Self.paragraphs(view)
                _ = try Self.press(window, view, caret: caret, offset: offset)
                let source = Self.paragraphs(view)
                let pairs = zip(live, source)
                report.append(
                    "\(live.count) paragraphs, \(pairs.count { $0.lines != $1.lines }) rewrapped, \(pairs.count { abs($0.height - $1.height) > 0.5 }) change height; "
                        + "lines Live \(live.reduce(0) { $0 + $1.lines }), Source \(source.reduce(0) { $0 + $1.lines })"
                )
            }
        }
        print("SOURCE-MODE \(lineHeight) pt Source lines, 1 MB: " + report.joined(separator: "; "))
    }

    @Test(arguments: TextKitVariant.allCases)
    func fullLayoutWithoutAToggle(_ variant: TextKitVariant) throws {
        let (window, view, caret) = try Self.editor(variant, bytes: 1_000_000)
        defer { window.close() }
        let offset = try #require(view.baseline(at: caret)) - view.visibleRect.minY
        Self.layOutEverything(view)
        Self.frame(window)
        let moved = try #require(view.baseline(at: caret)) - view.visibleRect.minY - offset
        print("SOURCE-MODE \(variant) 1 MB control: full layout with no toggle moves the caret line \(String(format: "%.1f", moved)) pt")
    }
}
