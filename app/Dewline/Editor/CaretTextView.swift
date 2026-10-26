import AppKit

/// The system caret in the accent and solid after five seconds without input.
class CaretTextView: NSTextView {
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
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idleTimer?.cancel()
        idleTimer = nil
        guard let window else { return }
        insertionPointColor = Self.accent
        center.addObserver(self, selector: #selector(keyStateDidChange(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(keyStateDidChange(_:)), name: NSWindow.didResignKeyNotification, object: window)
        let input: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify]
        monitor = NSEvent.addLocalMonitorForEvents(matching: input) { [weak self] event in
            if let self, event.window === self.window { restartIdleClock() }
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
}
