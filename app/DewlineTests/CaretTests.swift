import AppKit
import Testing
@testable import Dewline

/// The editor in a window that reports itself key and is never ordered front, so the system indicator exists.
@MainActor
private struct Caret {
    let window: KeyWindow
    let view: EditorTextView

    init(_ variant: TextKitVariant, lines: Int = 60) throws {
        let scrollView = EditorTextView.scrollView(variant: variant)
        window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = try #require(scrollView.documentView as? EditorTextView)
        view.string = (1...lines).map { "Line \($0) has **strong** words and *quiet* ones to read." }.joined(separator: "\n")
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        window.displayIfNeeded()
    }

    /// An input event through the application, the path the idle clock listens on.
    func input() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0
        ))
        #expect(event.window === window)
        NSApp.sendEvent(event)
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class Moment {
    var time: ContinuousClock.Instant?
}

@MainActor
struct CaretTests {
    @Test(arguments: TextKitVariant.allCases)
    func caretTakesTheAccent(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        #expect(caret.view.insertionPointColor == CaretTextView.accent)
        #expect(caret.view.indicator?.color == CaretTextView.accent)
    }

    /// Acceptance test 3 in the test host: solid five seconds after the last input, through NSTextView's own
    /// indicator updates and selection changes from code, and automatic again on the next input.
    @Test(arguments: TextKitVariant.allCases)
    func caretTurnsSolidFiveSecondsAfterInput(_ variant: TextKitVariant) async throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        let indicator = try #require(caret.view.indicator)
        let solid = Moment()
        let observation = indicator.observe(\.displayMode) { indicator, _ in
            MainActor.assumeIsolated {
                if indicator.displayMode == .visible && solid.time == nil { solid.time = .now }
            }
        }
        defer { observation.invalidate() }
        let start = ContinuousClock.now
        try caret.input()
        try await Task.sleep(for: .seconds(5.7))
        let after = try #require(solid.time) - start
        #expect(after >= .seconds(5), "solid after \(after)")
        #expect(indicator.displayMode == .visible)
        caret.view.updateInsertionPointStateAndRestartTimer(true)
        caret.view.needsLayout = true
        caret.view.layoutSubtreeIfNeeded()
        caret.view.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(indicator.displayMode == .visible)
        try caret.input()
        #expect(indicator.displayMode != .visible)
    }
}
