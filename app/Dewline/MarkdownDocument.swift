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
        let scrollView = EditorTextView.scrollView(variant: .current)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        // Rendered blocks fit the column, so the text arrives once the view has its width.
        let textView = scrollView.documentView as! EditorTextView
        textView.documentFolder = fileURL?.deletingLastPathComponent()
        textView.string = text
        window.center()
        addWindowController(NSWindowController(window: window))
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
