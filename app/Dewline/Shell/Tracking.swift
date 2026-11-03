import AppKit
import os

/// Failures that switch change tracking off, said once in the status bar ("Change tracking is off · Details") instead
/// of only in the log.
@MainActor
enum Tracking {
    enum Problem: Equatable {
        /// The engine didn't start, so notes save without snapshots or marks.
        case noEngine(String)
        /// The control socket didn't start, so the dewline command and agent hooks can't reach the app.
        case noSocket(String)

        var details: String {
            switch self {
            case .noEngine(let error):
                "Notes still save, but Dewline can\u{2019}t mark outside changes or keep earlier versions. The engine reported: \(error)"
            case .noSocket(let error):
                "The dewline command and agent hooks can\u{2019}t reach the app, so agent edits aren\u{2019}t named. The system reported: \(error)"
            }
        }
    }

    static let didChange = Notification.Name("DewlineTrackingDidChange")
    private(set) static var problems: [Problem] = []

    static func report(_ problem: Problem) {
        Logger(subsystem: "dev.arkwerx.dewline", category: "tracking").error("\(problem.details, privacy: .public)")
        guard !problems.contains(problem) else { return }
        problems.append(problem)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The status bar's Details: what stopped and what still works.
    static func showDetails(in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Change tracking is off"
        alert.informativeText = problems.map(\.details).joined(separator: "\n\n") + "\n\nQuit and reopen Dewline to try again."
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
