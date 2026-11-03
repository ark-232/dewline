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

/// The status bar lines the app posts: an export's result until the next keystroke, and "Change tracking is off" in
/// every main window while a tracking problem stands.
@MainActor
enum FlowStatus {
    static func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: Export.didExport, object: nil, queue: .main) { note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated {
                StatusBar.post(.init(id: "export", kind: .result, text: "Exported \u{201C}\(url.lastPathComponent)\u{201D}", actions: [
                    .init(title: "Show in Finder") { _ in NSWorkspace.shared.activateFileViewerSelecting([url]) }
                ], untilTyping: true))
            }
        }
        center.addObserver(forName: Tracking.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(postTracking) }
        }
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.mainWindow.map(postTracking) }
        }
    }

    private static func postTracking(in window: NSWindow) {
        guard !Tracking.problems.isEmpty, window.windowController is MainWindowController else { return }
        StatusBar.post(.init(id: "tracking", kind: .problem, text: "Change tracking is off", actions: [
            .init(title: "Details") { view in Tracking.showDetails(in: view.window) }
        ]), in: window)
    }
}
