import AppKit

/// The markdown editor: hides syntax through `MarkdownStyler` and defers styling while an input method composes.
final class EditorTextView: NSTextView {
    let styler = MarkdownStyler()
    private let hiddenGlyphs = HiddenGlyphs()
    private var composing = false

    var defersStyling: Bool {
        composing || hasMarkedText()
    }

    // The root of the TextKit object graph, which a text view built on a given container does not retain.
    private let content: NSObject

    init(variant: TextKitVariant) {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        switch variant {
        case .textKit1:
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)
            content = storage
        case .textKit2:
            let layoutManager = NSTextLayoutManager()
            layoutManager.textContainer = container
            let storage = NSTextContentStorage()
            storage.addTextLayoutManager(layoutManager)
            content = storage
        }
        super.init(frame: .zero, textContainer: container)
        if variant == .textKit1 {
            layoutManager?.delegate = hiddenGlyphs
        }
        styler.textView = self
        delegate = styler
        textStorage?.delegate = styler
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = true
        textContainerInset = NSSize(width: 24, height: 24)
        typingAttributes = [.font: MarkdownStyler.bodyFont, .foregroundColor: NSColor.labelColor]
    }

    required init?(coder: NSCoder) {
        fatalError("EditorTextView is built in code")
    }

    static func scrollView(variant: TextKitVariant) -> NSScrollView {
        let textView = EditorTextView(variant: variant)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        composing = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composing = false
        if !hasMarkedText() { styler.flush() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let commits = hasMarkedText()
        composing = commits
        super.insertText(string, replacementRange: replacementRange)
        composing = false
        if commits { styler.flush() }
    }

    override func unmarkText() {
        composing = true
        super.unmarkText()
        composing = false
        styler.flush()
    }
}
