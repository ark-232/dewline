import AppKit

/// The system caret in the accent and solid after five seconds without input, with the streak or landing mark a
/// jump, a click or a long move shows. Edits, arrows and key repeat always snap.
class CaretTextView: NSTextView {
    let effects = CaretEffectsView()
    private var monitor: Any?
    private var idleTimer: DispatchSourceTimer?
    private var lastInput = DispatchTime.now()
    private var solid = false

    /// Cobalt, oklch(0.50 0.20 266) in light and oklch(0.74 0.13 266) in dark, until themes land.
    static let accent = NSColor(name: "accent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.5182, green: 0.6583, blue: 0.9922, alpha: 1)
            : NSColor(srgbRed: 0.1764, green: 0.3300, blue: 0.8269, alpha: 1)
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
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idleTimer?.cancel()
        idleTimer = nil
        guard let window else { return }
        insertionPointColor = Self.accent
        if effects.superview == nil {
            effects.frame = bounds
            effects.autoresizingMask = [.width, .height]
            if let indicator { addSubview(effects, positioned: .below, relativeTo: indicator) } else { addSubview(effects) }
        }
        center.addObserver(self, selector: #selector(keyStateDidChange(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(keyStateDidChange(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(storageDidEdit(_:)), name: NSTextStorage.didProcessEditingNotification, object: textStorage)
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
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        holdSolid()
    }

    override func layout() {
        super.layout()
        holdSolid()
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

    /// Moves the selection as Go to Line does, and as Quick Open and the outline will.
    func jump(to range: NSRange) {
        move(.jump) {
            setSelectedRange(range)
            scrollRangeToVisible(range)
        }
    }

    func jump(toLine line: Int) {
        guard let text = textStorage?.mutableString else { return }
        var start = 0
        var remaining = line
        while remaining > 1, start < text.length {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            remaining -= 1
        }
        jump(to: NSRange(location: start, length: 0))
    }

    @objc func goToLine(_ sender: Any?) {
        guard let window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
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
        let repeating = NSApp.currentEvent.map { $0.type == .keyDown && $0.isARepeat } ?? false
        guard Self.longMoves.contains(selector), !repeating else { return super.doCommand(by: selector) }
        move(.longMove) { super.doCommand(by: selector) }
    }

    /// Runs a move the user asked for, then shows what the Motion level allows: the streak when the view did not
    /// scroll and both caret rects are visible, otherwise the landing mark after a jump. Find has no landing mark
    /// because its selected match marks the target.
    private func move(_ cause: Cause, _ body: () -> Void) {
        let level = Motion.current
        let jumps = cause == .jump || cause == .find
        guard jumps || level == .lively, !hasMarkedText() else { return body() }
        let from = selectedRange().location
        let old = caretRect(at: from)
        let visible = visibleRect
        body()
        effects.removeStreak()
        let selection = selectedRange()
        let new = caretRect(at: selection.location)
        let streaks = level != .off && new != old && visibleRect.origin == visible.origin && visible.contains(old) && visibleRect.contains(new)
        if jumps {
            if streaks {
                effects.streak(from: old, to: new, color: accentColor)
            } else if cause == .jump {
                let line = NSRect(x: textContainerOrigin.x, y: new.minY, width: textContainer?.size.width ?? bounds.width, height: new.height)
                effects.mark(line, color: accentColor, fades: level != .off)
            }
        } else if streaks, selection.length == 0, abs(new.midY - old.midY) >= 1.5 * old.height || abs(selection.location - from) >= 12 {
            effects.streak(from: old, to: new, color: accentColor)
        }
    }

    /// The caret at a character index in view coordinates, 2 pt wide like the system bar.
    private func caretRect(at location: Int) -> NSRect {
        guard let window else { return .zero }
        let rect = convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)), from: nil)
        return NSRect(x: rect.minX - 1, y: rect.minY, width: 2, height: rect.height)
    }

    private var accentColor: CGColor {
        var color = Self.accent.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = Self.accent.cgColor }
        return color
    }
}
