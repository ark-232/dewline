import AppKit

/// The finished page beside the text: a read-only copy of the note with every piece of Markdown syntax hidden, drawn by
/// the editor's own styler and theme. It takes the note's text 150 ms after typing stops and scrolls with the editor,
/// block by block.
final class PreviewPane: NSViewController {
    private(set) var textView: EditorTextView!
    private var update: Task<Void, Never>?
    private weak var editor: EditorTextView?

    override func loadView() {
        let scrollView = EditorTextView.scrollView()
        let textView = scrollView.documentView as! EditorTextView
        if textView.styler.showsSource { textView.styler.toggleSource(restyling: NSRange()) }
        textView.isEditable = false
        // A caret would reveal the syntax of the block it sits in.
        textView.isSelectable = false
        textView.setAccessibilityLabel("Preview")
        self.textView = textView
        view = scrollView
    }

    /// Shows `editor`'s note now and follows its text and scrolling from here on.
    func show(_ editor: EditorTextView?) {
        _ = view
        self.editor = editor
        update?.cancel()
        guard let editor else {
            textView.string = ""
            return
        }
        textView.documentFolder = editor.documentFolder
        textView.noteFolder = editor.noteFolder
        take(editor)
    }

    /// The note changed: the preview takes it once typing has stopped for 150 ms.
    func textChanged() {
        update?.cancel()
        update = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let editor = self.editor else { return }
            self.take(editor)
        }
    }

    private func take(_ editor: EditorTextView) {
        guard textView.string != editor.string else { return follow() }
        textView.string = editor.string
        // At the end of the text, past the last block, the caret reveals nothing.
        textView.setSelectedRange(NSRange(location: textView.textStorage!.length, length: 0))
        follow()
    }

    /// Puts the block at the top of the editor at the same height at the top of the preview.
    func follow() {
        guard let editor, let scrollView = editor.enclosingScrollView, textView.textStorage!.length > 0 else { return }
        let visible = editor.visibleRect
        let probe = NSPoint(x: editor.textContainerOrigin.x + 4, y: max(visible.minY + scrollView.contentInsets.top + 8, editor.textContainerOrigin.y))
        let top = editor.characterIndexForInsertion(at: probe)
        let start = editor.styler.map.blocks(touching: NSRange(location: top, length: 0)).first?.range.location ?? top
        guard let baseline = editor.baseline(at: start) else { return }
        textView.hold(min(start, textView.textStorage!.length - 1), at: baseline - visible.minY)
    }
}
