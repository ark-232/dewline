import Darwin

/// Stamps the begin and end of the editor's parts of a keystroke on the main thread, in the order they run, while a
/// test turns it on (DewlineTests/KeystrokeLatency.swift). Off, a stamp is a load and a branch.
enum LatencyProbe {
    enum Part: UInt16 {
        case parse = 1, attributes, reveal, caret
    }

    nonisolated(unsafe) static var enabled = false
    /// A part's raw value times two at its begin, plus one at its end; ticks from mach_absolute_time.
    nonisolated(unsafe) static var stamps: [(code: UInt16, ticks: UInt64)] = []

    @inline(__always) static func begin(_ part: Part) {
        guard enabled else { return }
        stamp(part.rawValue << 1)
    }

    @inline(__always) static func end(_ part: Part) {
        guard enabled else { return }
        stamp(part.rawValue << 1 | 1)
    }

    static func stamp(_ code: UInt16) {
        if enabled, pthread_main_np() != 0 { stamps.append((code, mach_absolute_time())) }
    }
}
