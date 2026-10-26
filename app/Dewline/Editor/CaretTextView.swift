import AppKit

/// The system caret in the accent and solid after five seconds without input, with the streak or landing mark a
/// jump, a click or a long move shows. Edits, arrows and key repeat always snap.
class CaretTextView: NSTextView {
    let effects = CaretEffectsView()
    private var monitor: Any?
    private var idleTimer: DispatchSourceTimer?
    private var lastInput = DispatchTime.now()
    private var solid = false

    /// The theme's accent, light and dark.
    static var accent: NSColor {
        ThemeStore.shared.color(.accent)
    }

    var indicator: NSTextInsertionIndicator? {
        subviews.lazy.compactMap { $0 as? NSTextInsertionIndicator }.first
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
        center.removeObserver(self, name: ThemeStore.didChange, object: ThemeStore.shared)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idleTimer?.cancel()
        idleTimer = nil
        solid = false
        guard let window else { return }
        insertionPointColor = Self.accent
        if effects.superview == nil {
            effects.frame = bounds
            effects.autoresizingMask = [.width, .height]
            addSubview(effects)
        }
        center.addObserver(self, selector: #selector(keyStateDidChange(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(keyStateDidChange(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(storageDidEdit(_:)), name: NSTextStorage.didProcessEditingNotification, object: textStorage)
        center.addObserver(self, selector: #selector(accentDidChange(_:)), name: ThemeStore.didChange, object: ThemeStore.shared)
        let input: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify]
        monitor = NSEvent.addLocalMonitorForEvents(matching: input) { [weak self] event in
            if let self, event.window === self.window {
                effects.clearMark()
                restartIdleClock()
            }
            return event
        }
        if window.isKeyWindow { restartIdleClock() }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        idleTimer?.cancel()
    }

    @objc private func accentDidChange(_ notification: Notification) {
        insertionPointColor = Self.accent
    }

    @objc private func keyStateDidChange(_ notification: Notification) {
        if window?.isKeyWindow == true {
            restartIdleClock()
        } else {
            idleTimer?.cancel()
            idleTimer = nil
            solid = false
        }
    }

    /// Any change to the characters, from any writer, ends a streak in the same transaction as the change.
    @objc private func storageDidEdit(_ notification: Notification) {
        guard (notification.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) == true else { return }
        effects.removeStreak()
    }

    /// One timestamp and one one-shot timer: typing costs at most one wakeup per five seconds and idle costs none.
    private func restartIdleClock() {
        lastInput = .now()
        if solid {
            solid = false
            indicator?.displayMode = .automatic
        }
        if idleTimer == nil { armIdleTimer() }
    }

    private func armIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: lastInput + 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.idleTimerFired() }
        }
        timer.activate()
        idleTimer = timer
    }

    private func idleTimerFired() {
        idleTimer?.cancel()
        idleTimer = nil
        if DispatchTime.now() < lastInput + 5 { return armIdleTimer() }
        solid = window?.isKeyWindow == true && window?.firstResponder === self
        holdSolid()
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        LatencyProbe.begin(.caret)
        defer { LatencyProbe.end(.caret) }
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        holdSolid()
        followMark()
    }

    override func layout() {
        super.layout()
        holdSolid()
        followMark()
    }

    /// NSTextView sets its indicator back to automatic whenever it updates it, and TextKit 2 does so on every
    /// layout pass; at idle the caret stays solid.
    private func holdSolid() {
        guard solid, window?.isKeyWindow == true, window?.firstResponder === self else { return }
        indicator?.displayMode = .visible
    }

    private enum Cause { case jump, find, click, longMove }

    private static let longMoves: Set<Selector> = [
        #selector(moveToBeginningOfDocument(_:)), #selector(moveToEndOfDocument(_:)),
        #selector(moveToBeginningOfLine(_:)), #selector(moveToEndOfLine(_:)),
        #selector(moveToLeftEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)),
        #selector(pageUp(_:)), #selector(pageDown(_:)),
    ]

    /// Moves the selection as Go to Line does.
    func jump(to range: NSRange) {
        move(.jump) {
            setSelectedRange(range)
            scrollRangeToVisible(range)
        }
    }

    /// Lines and columns count from 1. A column counts characters as the reader sees them and stops at the line's end.
    func jump(toLine line: Int, column: Int = 1) {
        let text = textStorage!.mutableString
        var start = 0
        var remaining = line
        while remaining > 1, start < text.length {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            remaining -= 1
        }
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
        var location = start
        remaining = column
        while remaining > 1, location < end {
            location = NSMaxRange(text.rangeOfComposedCharacterSequence(at: location))
            remaining -= 1
        }
        jump(to: NSRange(location: location, length: 0))
    }

    @objc func goToLine(_ sender: Any?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window!) { [weak self] response in
            if response == .alertFirstButtonReturn, let line = Int(field.stringValue) { self?.jump(toLine: line) }
        }
    }

    override func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag
        guard tag == NSTextFinder.Action.nextMatch.rawValue || tag == NSTextFinder.Action.previousMatch.rawValue else {
            return super.performFindPanelAction(sender)
        }
        move(.find) { super.performFindPanelAction(sender) }
    }

    override func mouseDown(with event: NSEvent) {
        guard window?.isKeyWindow == true else { return super.mouseDown(with: event) }
        move(.click) { super.mouseDown(with: event) }
    }

    override func doCommand(by selector: Selector) {
        guard Self.longMoves.contains(selector) else { return super.doCommand(by: selector) }
        move(.longMove) { super.doCommand(by: selector) }
    }

    /// Runs a move the user asked for, then shows what the Motion level allows: the streak when the view did not
    /// scroll and both caret rects are visible, otherwise the landing mark after a jump. A key repeat snaps. Find
    /// has no landing mark because its selected match marks the target.
    private func move(_ cause: Cause, _ body: () -> Void) {
        let level = Motion.current
        let jumps = cause == .jump || cause == .find
        let repeating = NSApp.currentEvent.map { $0.type == .keyDown && $0.isARepeat } ?? false
        guard let window, jumps || level == .lively, !repeating, !hasMarkedText() else { return body() }
        let from = selectedRange().location
        let old = caretRect(at: from, in: window)
        let visible = visibleRect
        body()
        // TextKit 2 corrects its estimated layout around the new selection now instead of at the next display.
        layoutSubtreeIfNeeded()
        effects.removeStreak()
        let selection = selectedRange()
        let new = caretRect(at: selection.location, in: window)
        let streaks = level != .off && new != old && visibleRect.origin == visible.origin && visible.contains(old) && visibleRect.contains(new)
        if jumps {
            if streaks {
                effects.streak(from: old, to: new, color: accentColor)
            } else if cause == .jump {
                effects.mark(line(around: new), color: accentColor, fades: level != .off)
            }
        } else if streaks, selection.length == 0, abs(new.midY - old.midY) >= 1.5 * old.height || abs(selection.location - from) >= 12 {
            effects.streak(from: old, to: new, color: accentColor)
        }
    }

    /// The landing mark stays on the caret's line while the layout above it settles, which on a document opened
    /// moments earlier moves the line by hundreds of points.
    private func followMark() {
        guard effects.marking, let window else { return }
        let caret = caretRect(at: selectedRange().location, in: window)
        if visibleRect.intersects(caret) { effects.moveMark(to: line(around: caret)) }
    }

    /// The caret at a character index in view coordinates, 2 pt wide like the system bar; `firstRect` is empty for
    /// a caret outside the visible rect.
    private func caretRect(at location: Int, in window: NSWindow) -> NSRect {
        let rect = convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)), from: nil)
        return NSRect(x: rect.minX - 1, y: rect.minY, width: 2, height: rect.height)
    }

    private func line(around caret: NSRect) -> NSRect {
        NSRect(x: textContainerOrigin.x, y: caret.minY, width: textContainer!.size.width, height: caret.height)
    }

    private var accentColor: CGColor {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = Self.accent.cgColor }
        return color!
    }
}
