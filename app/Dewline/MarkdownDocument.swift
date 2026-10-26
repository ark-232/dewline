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
        (scrollView.documentView as! NSTextView).string = text

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
