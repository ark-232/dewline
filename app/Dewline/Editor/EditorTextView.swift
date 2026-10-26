import AppKit

/// The markdown editor: hides syntax through `MarkdownStyler` and defers styling while an input method composes.
final class EditorTextView: NSTextView {
    let styler = MarkdownStyler()
    private let hiddenGlyphs = HiddenGlyphs()
    private var composing = false
    private var toggleWaits = false
    private var held: (anchor: Int, offset: CGFloat)?

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
        usesFindBar = true
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
        if !hasMarkedText() { compositionEnded() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let commits = hasMarkedText()
        composing = commits
        super.insertText(string, replacementRange: replacementRange)
        composing = false
        if commits { compositionEnded() }
    }

    override func unmarkText() {
        composing = true
        super.unmarkText()
        composing = false
        compositionEnded()
    }

    private func compositionEnded() {
        styler.flush()
        if toggleWaits {
            toggleWaits = false
            toggleSource(nil)
        }
    }

    /// Switches between the rendered document and its source, holding the caret's line (or the first visible line) in place.
    @objc func toggleSource(_ sender: Any?) {
        guard !defersStyling else {
            toggleWaits.toggle()
            return
        }
        let storage = textStorage!
        let visible = visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text, so the probe stays below the inset.
        let first = characterIndexForInsertion(at: NSPoint(x: visible.minX, y: max(visible.minY, textContainerOrigin.y)))
        let last = characterIndexForInsertion(at: NSPoint(x: visible.maxX, y: visible.maxY))
        let caret = selectedRange().location
        let anchor = min(first <= caret && caret <= last ? caret : first, storage.length - 1)
        var offset = baseline(at: anchor).map { $0 - visible.minY }
        // The clip view snaps each landing to the pixel grid, so a line left where the last toggle put it aims for that toggle's offset.
        if let held, let measured = offset, held.anchor == anchor, abs(held.offset - measured) <= 0.5 {
            offset = held.offset
        }
        held = offset.map { (anchor, $0) }

        let scrollView = enclosingScrollView!
        let clipView = scrollView.contentView
        var snapshot: CALayer?
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let host = scrollView.layer,
            let bitmap = clipView.bitmapImageRepForCachingDisplay(in: clipView.bounds) {
            clipView.cacheDisplay(in: clipView.bounds, to: bitmap)
            let layer = CALayer()
            layer.contents = bitmap.cgImage
            layer.frame = clipView.frame
            host.insertSublayer(layer, above: clipView.layer)
            snapshot = layer
        }

        styler.toggleSource()
        if storage.length > 0 {
            // Typing attributes follow the selection only when it moves, and marked text draws with them before any restyle.
            let neighbor = storage.attributes(at: max(caret - 1, 0), effectiveRange: nil)
            for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
                typingAttributes[key] = neighbor[key]
            }
        }
        if let offset, let restyled = baseline(at: anchor) {
            let target = NSRect(x: visible.minX, y: restyled - offset, width: visible.width, height: visible.height)
            if let layout = textLayoutManager {
                scroll(target.origin)
                // TextKit 2 restacks the viewport from its top fragment's estimated position; lay it out, then correct.
                layout.textViewportLayoutController.layoutViewport()
                if let restacked = baseline(at: anchor) {
                    scroll(NSPoint(x: visible.minX, y: restacked - offset))
                }
            } else if let layout = layoutManager, let container = textContainer {
                // TextKit 1 sizes the view only as far as it has laid out.
                layout.ensureLayout(forBoundingRect: target.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: container)
                scroll(target.origin)
            }
        }

        if let snapshot {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { snapshot.removeFromSuperlayer() }
            snapshot.opacity = 0
            snapshot.add(fade, forKey: nil)
            CATransaction.commit()
        }
    }

    /// The baseline of the line holding the character at `index`, in this view's coordinates.
    func baseline(at index: Int) -> CGFloat? {
        guard index >= 0, index < textStorage!.length else { return nil }
        if let layout = textLayoutManager {
            guard let content = layout.textContentManager,
                let location = content.location(content.documentRange.location, offsetBy: index)
            else { return nil }
            layout.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
            let offset = content.offset(from: fragment.rangeInElement.location, to: location)
            guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(offset, $0.characterRange) }) else { return nil }
            return textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        }
        guard let layout = layoutManager else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: index)
        return textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + layout.location(forGlyphAt: glyph).y
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleSource(_:)) else { return super.validateMenuItem(menuItem) }
        menuItem.state = styler.showsSource ? .on : .off
        return true
    }
}
