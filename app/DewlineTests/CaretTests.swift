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

    var streaking: Bool {
        view.effects.streak.animation(forKey: "streak") != nil
    }

    /// The system caret's bar in the text view's coordinates.
    var systemCaret: NSRect? {
        view.indicator.map { NSRect(x: $0.frame.minX - 1, y: $0.frame.minY, width: 2, height: $0.frame.height) }
    }

    /// An input event through the application, the path the idle clock and the landing mark listen on.
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

/// Runs the body with the Motion setting in the volatile argument domain, which a launch argument would fill.
@MainActor
private func motion(_ level: Motion, _ body: () throws -> Void) rethrows {
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(arguments.merging(["DewlineMotion": level.rawValue]) { $1 }, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
    try body()
}

@MainActor
private final class Moment {
    var time: ContinuousClock.Instant?
}

private let systemAllowsMotion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
private let systemAllowsLively = systemAllowsMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled

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
        while solid.time == nil && ContinuousClock.now - start < .seconds(10) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let after = try #require(solid.time) - start
        #expect(after >= .seconds(5), "solid after \(after)")
        #expect(indicator.displayMode == .visible)
        caret.view.updateInsertionPointStateAndRestartTimer(true)
        caret.view.needsLayout = true
        caret.view.layoutSubtreeIfNeeded()
        caret.view.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(indicator.displayMode == .visible)
        caret.window.key = false
        caret.window.resignKey()
        caret.window.key = true
        caret.window.becomeKey()
        #expect(indicator.displayMode != .visible, "blinking again once the window is key again")
        solid.time = nil
        let again = ContinuousClock.now
        while solid.time == nil && ContinuousClock.now - again < .seconds(10) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let restarted = try #require(solid.time) - again
        #expect(restarted >= .seconds(5), "the clock restarts when the window becomes key: solid after \(restarted)")
        try caret.input()
        #expect(indicator.displayMode != .visible)
    }

    @Test(.enabled(if: systemAllowsMotion), arguments: TextKitVariant.allCases)
    func jumpStreaksOntoTheSystemCaret(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        try motion(.calm) {
            caret.view.jump(toLine: 6)
            #expect(caret.streaking)
            #expect(caret.view.effects.mark.animation(forKey: "mark") == nil)
            caret.window.displayIfNeeded()
            #expect(caret.view.effects.layer?.contents == nil, "the effects view as tall as the document has no backing store")
            let target = try #require(caret.systemCaret)
            let path = try #require(caret.view.effects.streak.path).boundingBox
            #expect(abs(path.minX - target.minX) <= 0.5 && abs(path.minY - target.minY) <= 0.5, "\(path) against \(target)")
            #expect(abs(path.height - target.height) <= 0.5)
        }
    }

    @Test(.enabled(if: systemAllowsMotion), arguments: TextKitVariant.allCases)
    func jumpThatScrollsMarksTheLine(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        try motion(.calm) {
            let top = caret.view.visibleRect.minY
            caret.view.jump(toLine: 55)
            #expect(caret.view.visibleRect.minY > top)
            #expect(!caret.streaking)
            let mark = caret.view.effects.mark
            #expect(mark.animation(forKey: "mark") != nil && mark.opacity == 0)
            caret.window.displayIfNeeded()
            let line = try #require(mark.path).boundingBox
            let target = try #require(caret.systemCaret)
            #expect(line.minY <= target.minY + 1 && line.maxY >= target.maxY - 1 && line.width > 600, "\(line) around \(target)")
        }
    }
}

private struct State: Equatable {
    let length: Int
    let caret: NSRect?
    let streaking: Bool
}

@MainActor
private final class Commits {
    var states: [State] = []
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

extension CaretTests {
    /// Acceptance test 2: with a streak in flight, typing ends it before `insertText` returns and leaves the glyph
    /// left of the caret; the first commit after the edit holds both, and no later commit moves the caret.
    @Test(.enabled(if: systemAllowsMotion), arguments: TextKitVariant.allCases)
    func glyphLandsBeforeTheCaretInOneCommit(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        let view = caret.view
        try motion(.lively) {
            view.jump(toLine: 4)
            #expect(caret.streaking)
            let at = view.selectedRange().location
            let length = view.textStorage?.length ?? 0
            let commits = Commits()
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { _, _ in
                MainActor.assumeIsolated {
                    commits.states.append(State(length: view.textStorage?.length ?? 0, caret: caret.systemCaret, streaking: caret.streaking))
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            defer { CFRunLoopObserverInvalidate(observer) }
            view.insertText("a", replacementRange: view.selectedRange())
            #expect(!caret.streaking)
            #expect(view.selectedRange() == NSRange(location: at + 1, length: 0))
            let glyph = view.firstRect(forCharacterRange: NSRange(location: at, length: 1), actualRange: nil)
            let after = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
            #expect(abs(after.minX - glyph.maxX) <= 0.5, "caret \(after) after glyph \(glyph)")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let first = try #require(commits.states.first)
            let expected = view.convert(caret.window.convertFromScreen(after), from: nil)
            let system = try #require(first.caret)
            #expect(first.length == length + 1 && !first.streaking)
            #expect(abs(system.midX - expected.minX) <= 0.5, "system caret \(system) at \(expected)")
            #expect(commits.states.allSatisfy { $0 == first }, "\(commits.states)")
        }
    }

    /// Acceptance test 2's property: 1,000 random edits at Lively, half of them right after a jump that may start
    /// a streak; once the text changes no streak runs, and an edit never starts one.
    @Test(.enabled(if: systemAllowsMotion), arguments: TextKitVariant.allCases)
    func editsNeverRunTheStreak(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant, lines: 40)
        defer { caret.close() }
        let view = caret.view
        let undo = view.styler.undoManager
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.caret"))
        pasteboard.clearContents()
        pasteboard.setString("pasted **text**", forType: .string)
        defer { pasteboard.releaseGlobally() }
        var random = SplitMix(state: 0xDE11_0E)
        var edited = 0
        var streaks = 0
        // Each edit gets its own undo group, as each event does in the app; NSUndoManager raises on a registration
        // outside a group, and an Objective-C exception through Swift frames takes the test host down.
        try #require(undo.groupingLevel == 0)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        motion(.lively) {
            for step in 0..<1000 {
                if random.next() % 2 == 0 {
                    let length = view.textStorage?.length ?? 0
                    view.jump(to: NSRange(location: Int(random.next() % UInt64(min(length, 400) + 1)), length: 0))
                    if caret.streaking { streaks += 1 }
                }
                let before = caret.streaking
                let text = view.string
                let edit = random.next() % 8
                if edit == 4 {
                    if undo.canUndo { undo.undo() }
                } else if edit == 5 {
                    if undo.canRedo { undo.redo() }
                } else {
                    undo.beginUndoGrouping()
                    switch edit {
                    case 0: view.insertText(String("abc xyz".randomElement(using: &random) ?? "a"), replacementRange: view.selectedRange())
                    case 1: view.deleteBackward(nil)
                    case 2: view.deleteForward(nil)
                    case 3: _ = view.readSelection(from: pasteboard, type: .string)
                    case 6:
                        let partial = view.rangeForUserCompletion
                        if partial.location != NSNotFound {
                            view.insertCompletion("completion", forPartialWordRange: partial, movement: NSTextMovement.other.rawValue, isFinal: true)
                        }
                    default:
                        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                        view.insertText("か", replacementRange: view.markedRange())
                    }
                    undo.endUndoGrouping()
                }
                let changed = view.string != text
                if changed { edited += 1 }
                #expect(!caret.streaking || (before && !changed), "step \(step), edit \(edit)")
            }
        }
        #expect(edited > 700 && streaks > 100, "\(edited) edits changed the text, \(streaks) jumps streaked")
    }
}

extension CaretTests {
    /// Lively adds the streak to long keyboard moves and clicks; Calm snaps them, and so do plain arrows.
    @Test(.enabled(if: systemAllowsLively), arguments: TextKitVariant.allCases)
    func livelyStreaksLongMovesAndClicks(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        let view = caret.view
        motion(.calm) {
            view.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
            #expect(view.selectedRange().location > 12 && !caret.streaking)
        }
        try motion(.lively) {
            view.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
            #expect(view.selectedRange().location == 0 && caret.streaking)
            view.effects.removeStreak()
            view.doCommand(by: #selector(NSResponder.moveDown(_:)))
            #expect(!caret.streaking)
            let word = view.firstRect(forCharacterRange: NSRange(location: 300, length: 1), actualRange: nil)
            let point = caret.window.convertPoint(fromScreen: NSPoint(x: word.midX, y: word.midY))
            let click = { (type: NSEvent.EventType) in
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: caret.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let down = try #require(click(.leftMouseDown))
            NSApp.postEvent(try #require(click(.leftMouseUp)), atStart: false)
            view.mouseDown(with: down)
            #expect(abs(view.selectedRange().location - 300) <= 1 && caret.streaking)
        }
    }

    @Test func reduceMotionRunsOffAndLowPowerRunsLivelyAsCalm() {
        for setting in [Motion.off, .calm, .lively] {
            #expect(Motion.resolve(setting, reduceMotion: true, lowPower: false) == .off)
            #expect(Motion.resolve(setting, reduceMotion: true, lowPower: true) == .off)
            #expect(Motion.resolve(setting, reduceMotion: false, lowPower: false) == setting)
            #expect(Motion.resolve(setting, reduceMotion: false, lowPower: true) == (setting == .lively ? .calm : setting))
        }
    }

    /// The text view's first layout passes read `marking` before the effects view has a backing layer.
    @Test func aNewEffectsViewShowsNoMark() {
        #expect(!CaretEffectsView().marking)
    }

    /// Acceptance test 8 through Off, the level Reduce Motion runs: the streak layer never gets an animation, every
    /// jump gets the static landing mark until the next input, and a new level applies at the next jump.
    @Test(.enabled(if: systemAllowsMotion), arguments: TextKitVariant.allCases)
    func offMarksJumpsWithoutMotion(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        let effects = caret.view.effects
        try motion(.off) {
            caret.view.jump(toLine: 6)
            #expect(effects.mark.opacity == 1 && effects.mark.animation(forKey: "mark") == nil)
            try caret.input()
            #expect(effects.mark.opacity == 0)
            let top = caret.view.visibleRect.minY
            caret.view.jump(toLine: 55)
            #expect(caret.view.visibleRect.minY > top && effects.mark.opacity == 1)
            #expect(effects.streak.animationKeys() == nil)
        }
        motion(.calm) {
            caret.view.jump(toLine: 52)
            #expect(caret.streaking)
        }
        motion(.off) {
            caret.view.jump(toLine: 50)
            #expect(!caret.streaking)
        }
    }
}

extension CaretTests {
    /// Find Next is a jump: a match in view gets the streak; a match it scrolls to gets neither streak nor landing
    /// mark, because the selected match marks it.
    @Test(.enabled(if: systemAllowsMotion), arguments: TextKitVariant.allCases)
    func findNextIsAJump(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        let view = caret.view
        view.usesFindBar = true
        let pasteboard = NSPasteboard(name: .find)
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let find = { (action: NSTextFinder.Action) in
            let item = NSMenuItem()
            item.tag = action.rawValue
            view.performFindPanelAction(item)
        }
        let text = view.string as NSString
        motion(.calm) {
            view.setSelectedRange(text.range(of: "quiet"))
            find(.setSearchString)
            find(.nextMatch)
            #expect(view.selectedRange() == text.range(of: "quiet", range: NSRange(location: 60, length: text.length - 60)))
            #expect(caret.streaking)
            view.setSelectedRange(text.range(of: "Line 55 "))
            find(.setSearchString)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let top = view.visibleRect.minY
            find(.nextMatch)
            #expect(view.selectedRange() == text.range(of: "Line 55 ") && view.visibleRect.minY > top)
            #expect(!caret.streaking && !view.effects.marking)
        }
    }

    /// A key repeat snaps every move, a jump included.
    @Test(.enabled(if: systemAllowsMotion), arguments: TextKitVariant.allCases)
    func keyRepeatSnapsJumps(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        try motion(.calm) {
            for (repeating, line) in [(true, 8), (false, 12)] {
                let key = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: caret.window.windowNumber, context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: repeating, keyCode: 5
                ))
                NSApp.postEvent(key, atStart: true)
                let current = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true)
                try #require(current === NSApp.currentEvent && current?.isARepeat == repeating)
                caret.view.jump(toLine: line)
                #expect(caret.streaking == !repeating, "repeat \(repeating)")
            }
        }
    }

    /// The landing mark ends on the caret's line on wrapped paragraphs, both on a document opened just before the
    /// jump, while the layout above the target still moves, and on one already laid out.
    @Test(.enabled(if: systemAllowsMotion), arguments: TextKitVariant.allCases)
    func landingMarkSettlesOnTheCaretLine(_ variant: TextKitVariant) throws {
        let caret = try Caret(variant)
        defer { caret.close() }
        let view = caret.view
        view.string = (1...3000).map { "Line \($0) " + String(repeating: "wrapping words ", count: 20) }.joined(separator: "\n")
        let settledCaret = {
            for _ in 0..<20 {
                caret.window.displayIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            return view.convert(caret.window.convertFromScreen(view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)), from: nil)
        }
        try motion(.calm) {
            for (line, phase) in [(2000, "cold"), (300, "warm")] {
                view.jump(toLine: line)
                let placed = try #require(view.effects.mark.path).boundingBox
                let target = settledCaret()
                let mark = try #require(view.effects.mark.path).boundingBox
                #expect(target.height > 0 && view.visibleRect.contains(target), "\(phase): caret \(target) in \(view.visibleRect)")
                #expect(abs(mark.minY - 0.5 - target.minY) <= 1 && abs(mark.height + 1 - target.height) <= 1, "\(phase): mark \(mark) on caret \(target)")
                if phase == "warm" { #expect(placed == mark, "warm: placed at \(placed), settled at \(mark)") }
            }
        }
    }
}
