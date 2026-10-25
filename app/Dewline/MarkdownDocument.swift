import AppKit

/// A markdown file, shown read-only until saving goes through the engine.
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
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.string = text

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.center()
        addWindowController(NSWindowController(window: window))
    }
}
