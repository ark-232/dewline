import AppKit

/// A markdown file, editable but never saved until saving goes through the engine.
final class MarkdownDocument: NSDocument {
    private(set) var text = ""

    override class var autosavesInPlace: Bool {
        false
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        // Documents read on the main thread unless canConcurrentlyReadDocuments says otherwise.
        MainActor.assumeIsolated { text = decoded }
    }

    override func makeWindowControllers() {
        // A file inside the folder of the window in front opens there: in place of its empty page, else in a new tab.
        let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? MainWindowController }.first
        guard let front, let folder = front.folder, fileURL.map({ folder.relativePath(of: $0) != nil }) ?? true else {
            MainWindowController(folder: nil).display(self)
            return
        }
        (front.document == nil ? front : MainWindowController(folder: folder)).display(self)
    }

    override func showWindows() {
        super.showWindows()
        if ProcessInfo.processInfo.environment["DEWLINE_CARET_PROBE"] != nil {
            ((windowControllers.first?.window?.contentView as? NSScrollView)?.documentView as? CaretTextView)?.probe()
        }
        // scripts/perf.sh: print milliseconds from process start to this first display, then quit.
        guard ProcessInfo.processInfo.environment["DEWLINE_LAUNCH_PROBE"] != nil else { return }
        windowControllers[0].window!.displayIfNeeded()
        CATransaction.flush()
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&name, 4, &process, &size, nil, 0)
        let start = process.kp_proc.p_starttime
        Swift.print(String(format: "%.1f", Date().timeIntervalSince1970 * 1000 - Double(start.tv_sec) * 1000 - Double(start.tv_usec) / 1000))
        exit(0)
    }
}
