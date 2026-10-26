import AppKit

extension CaretTextView {
    @MainActor private static var probeObservation: NSKeyValueObservation?

    /// scripts/caret-idle.sh, with `DEWLINE_CARET_PROBE` set: from the first line, a jump, a click and a jump that
    /// scrolls, then one input event. Prints what each showed, the caret's rect for `screencapture -R`, then every
    /// display mode the system indicator takes.
    func probe() {
        guard let window else { return }
        let start = DispatchTime.now()
        let log = { @Sendable (line: String) in
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            try? FileHandle.standardOutput.write(contentsOf: Data(String(format: "%.3f %@\n", seconds, line).utf8))
        }
        let streaking = { self.effects.streak.animation(forKey: "streak") != nil }
        let steps: [(Double, () -> Void)] = [
            (0.5, {
                self.setSelectedRange(NSRange(location: 0, length: 0))
                self.jump(toLine: 5)
                log("jump streak \(streaking())")
            }),
            (1.0, {
                let caret = self.firstRect(forCharacterRange: self.selectedRange(), actualRange: nil)
                let point = window.convertPoint(fromScreen: NSPoint(x: caret.minX + 60, y: caret.midY - 4 * caret.height))
                let click = { (type: NSEvent.EventType) in
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                guard let down = click(.leftMouseDown), let up = click(.leftMouseUp) else { return log("click failed") }
                NSApp.postEvent(up, atStart: false)
                NSApp.sendEvent(down)
                log("click streak \(streaking())")
            }),
            (1.5, {
                self.jump(toLine: .max)
                log("landing mark \(self.effects.mark.animation(forKey: "mark") != nil)")
            }),
            (2.5, {
                if let input = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                isARepeat: false, keyCode: 0) {
                    NSApp.sendEvent(input)
                }
                let caret = self.firstRect(forCharacterRange: self.selectedRange(), actualRange: nil)
                let top = (NSScreen.screens.first?.frame.height ?? 0) - caret.maxY
                log(String(format: "caret %.0f,%.0f,8,%.0f mode %d", caret.minX - 4, top - 2, caret.height + 4, self.indicator?.displayMode.rawValue ?? -1))
                Self.probeObservation = self.indicator?.observe(\.displayMode) { indicator, _ in
                    MainActor.assumeIsolated { log("mode \(indicator.displayMode.rawValue)") }
                }
                log("done")
            }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: start + delay) { MainActor.assumeIsolated(step) }
        }
    }
}
