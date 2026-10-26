import AppKit

/// The markdown editor: hides syntax through `MarkdownStyler` and defers styling while an input method composes.
final class EditorTextView: CaretTextView {
    let styler = MarkdownStyler()
    private let hiddenGlyphs = HiddenGlyphs()
    private let blockFragments = BlockFragments()
    private var composing = false
    private var toggleWaits = false
    private var held: (anchor: Int, offset: CGFloat)?
    private weak var snapshot: NSView?
    /// When the last toggle committed its first frame and started the fade.
    private(set) var fadeStarted: ContinuousClock.Instant?
    /// Where images in the document resolve from.
    var documentFolder: URL?

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
            let layoutManager = BlockLayoutManager()
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
        } else {
            textLayoutManager?.delegate = blockFragments
        }
        styler.textView = self
        styler.blocks.textView = self
        delegate = styler
        textStorage?.delegate = styler
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = true
        usesFindBar = true
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("EditorTextView is built in code")
    }

    static func scrollView(variant: TextKitVariant) -> NSScrollView {
        let textView = EditorTextView(variant: variant)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = textView.backgroundColor
        scrollView.documentView = textView
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    /// Paper, selection and typing attributes from the theme, and the column at its measure.
    private func applyTheme() {
        let store = ThemeStore.shared
        backgroundColor = store.color(.paper)
        enclosingScrollView?.backgroundColor = backgroundColor
        selectedTextAttributes = [.backgroundColor: store.color(.selection)]
        typingAttributes = styler.baseAttributes
        fitColumn(to: frame.width)
    }

    @objc private func themeDidChange(_ notification: Notification) {
        applyTheme()
        styler.themeDidChange()
    }

    /// Rendered diagrams and math take the colors of the appearance they were drawn in.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styler.restyleDocument()
    }

    override func setFrameSize(_ newSize: NSSize) {
        fitColumn(to: newSize.width)
        super.setFrameSize(newSize)
    }

    /// Centers the column at the measure, with margins of at least 32 pt; a narrower view fills.
    private func fitColumn(to width: CGFloat) {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let margin = max(32, ((width - ThemeStore.shared.measure) / 2 - padding).rounded(.down))
        if textContainerInset.width != margin {
            textContainerInset = NSSize(width: margin, height: 24)
        }
    }

    /// Draws each quote's rule at the column's left edge.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let storage = textStorage!
        guard !styler.showsSource, storage.length > 0, let window else { return }
        let first = characterIndexForInsertion(at: NSPoint(x: rect.minX, y: max(rect.minY, textContainerOrigin.y)))
        let last = characterIndexForInsertion(at: NSPoint(x: rect.maxX, y: rect.maxY))
        let visible = storage.mutableString.paragraphRange(for: NSRange(location: min(first, last), length: abs(last - first)))
        func line(at index: Int) -> NSRect {
            convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)), from: nil)
        }
        ThemeStore.shared.color(.quoteRule).setFill()
        storage.enumerateAttribute(.dewlineQuote, in: visible) { value, range, _ in
            guard value != nil else { return }
            let top = line(at: range.location)
            let bottom = line(at: max(NSMaxRange(range) - 1, range.location))
            NSRect(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: top.minY, width: 2, height: bottom.maxY - top.minY).fill()
        }
    }

    /// The text's children plus one image per rendered block, labeled with its source.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        let storage = textStorage!
        storage.enumerateAttribute(.dewlineBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard case .picture(let picture, let label)? = (value as? BlockLine)?.role else { return }
            let line = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
            let frame = NSRect(x: line.minX, y: line.maxY - picture.size.height, width: picture.size.width, height: picture.size.height)
            children.append(NSAccessibilityElement.element(withRole: .image, frame: frame, label: label, parent: self))
        }
        return children
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
        snapshot?.removeFromSuperview()
        let storage = textStorage!
        let visible = visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text, so probes stay below the inset.
        func index(_ x: CGFloat, _ y: CGFloat) -> Int {
            characterIndexForInsertion(at: NSPoint(x: x, y: max(y, textContainerOrigin.y)))
        }
        let first = index(visible.minX, visible.minY)
        let last = index(visible.maxX, visible.maxY)
        let caret = selectedRange().location
        let anchor = min(first <= caret && caret <= last ? caret : first, storage.length - 1)
        var offset = baseline(at: anchor).map { $0 - visible.minY }
        // The clip view snaps each landing to the pixel grid, so a line left where the last toggle put it aims for that toggle's offset.
        if let held, let measured = offset, held.anchor == anchor, abs(held.offset - measured) <= 0.5 {
            offset = held.offset
        }
        held = offset.map { (anchor, $0) }

        let caretView = subviews.first { $0 is NSTextInsertionIndicator }
        let caretWasHidden = caretView?.isHidden ?? true
        caretView?.isHidden = true
        let picture = bitmapImageRepForCachingDisplay(in: visible)
        if let picture { cacheDisplay(in: visible, to: picture) }
        caretView?.isHidden = caretWasHidden

        // The visible text and as much again on either side change first, so the fade starts before the rest restyles. TextKit 2
        // has no index for a point outside its laid-out viewport, so the margin counts characters, not points.
        let margin = max(last - first, 0)
        let lower = max(first - margin, 0)
        let upper = min(max(first, last) + margin, storage.length)
        styler.toggleSource(restyling: NSRange(location: lower, length: upper - lower))
        if let offset { hold(anchor, at: offset) }
        if let picture {
            let cover = Snapshot(frame: visibleRect)
            cover.wantsLayer = true
            cover.layer?.contents = picture.cgImage
            if let caretView { addSubview(cover, positioned: .below, relativeTo: caretView) } else { addSubview(cover) }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.3
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { cover.removeFromSuperview() } }
            cover.layer?.opacity = 0
            cover.layer?.add(fade, forKey: nil)
            CATransaction.commit()
            snapshot = cover
        }
        window?.layoutIfNeeded()
        window?.displayIfNeeded()
        CATransaction.flush()
        fadeStarted = .now

        styler.restyleDocument()
        if let offset { hold(anchor, at: offset) }
        snapshot?.frame = visibleRect
        // Typing attributes follow the selection only when it moves, and marked text draws with them before any restyle.
        let neighbor = storage.length > 0 ? storage.attributes(at: max(caret - 1, 0), effectiveRange: nil) : styler.baseAttributes
        for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
            typingAttributes[key] = neighbor[key]
        }
    }

    /// Scrolls so the baseline of the line holding `anchor` sits `offset` below the top of the visible rect.
    func hold(_ anchor: Int, at offset: CGFloat) {
        let visible = visibleRect
        if let layout = textLayoutManager {
            // TextKit 2 sizes the view and stacks the viewport from estimates it refreshes as it lays the viewport out:
            // lay out, scroll to the line, lay out again, correct. A refresh can leave the clip view a fraction of a pixel
            // off the grid, where a scroll to a point lands up to a pixel from it, so the scroll moves by whole pixels and
            // lands within half of one.
            let pixel = 1 / (window?.backingScaleFactor ?? 1)
            for _ in 0..<2 {
                layout.textViewportLayoutController.layoutViewport()
                guard let now = baseline(at: anchor) else { return }
                let top = visibleRect.minY
                scroll(NSPoint(x: visible.minX, y: top + ((now - offset - top) / pixel).rounded() * pixel))
            }
        } else if let layout = layoutManager, let container = textContainer, let restyled = baseline(at: anchor) {
            let target = NSRect(x: visible.minX, y: restyled - offset, width: visible.width, height: visible.height)
            // TextKit 1 sizes the view only as far as it has laid out.
            layout.ensureLayout(forBoundingRect: target.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: container)
            scroll(target.origin)
        }
    }

    override func didChangeText() {
        snapshot?.removeFromSuperview()
        super.didChangeText()
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

/// The frame before a toggle, fading out over the new one; clicks go through to the text.
private final class Snapshot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension NSAttributedString.Key {
    /// Marks a block quote's paragraph, which draws a rule at the column's left edge.
    static let dewlineQuote = NSAttributedString.Key("DewlineQuote")
}
