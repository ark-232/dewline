import AppKit

/// The markdown editor: hides syntax through `MarkdownStyler` and defers styling while an input method composes.
final class EditorTextView: CaretTextView {
    let styler = MarkdownStyler()
    private let blockFragments = BlockFragments()
    private var composing = false
    private var toggleWaits = false
    private var held: (anchor: Int, offset: CGFloat)?
    private weak var snapshot: NSView?
    /// When the last toggle committed its first frame and started the fade.
    private(set) var fadeStarted: ContinuousClock.Instant?
    /// Where images in the document resolve from.
    var documentFolder: URL?
    /// Where wikilinks resolve: the window's folder, else the document's.
    var noteFolder: URL?
    /// Opens a note a link points to, at a heading.
    var openNote: ((URL, String?) -> Void)?
    /// Runs Find in Files for a tag; until there is one, Cmd-clicking a tag beeps.
    var findInFiles: ((String) -> Void)?
    var footnotePopover: NSPopover?
    /// Vim's keys, while Vim mode is on.
    var vim: VimEngine? {
        didSet {
            vimStatus?.isHidden = vim == nil
            vimDidRun()
        }
    }
    private var vimStatus: NSTextField?

    var defersStyling: Bool {
        composing || hasMarkedText()
    }

    // The root of the TextKit object graph, which a text view built on a given container does not retain.
    private let content: NSObject

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let layout = NSTextLayoutManager()
        layout.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(layout)
        content = storage
        super.init(frame: .zero, textContainer: container)
        textLayoutManager?.delegate = blockFragments
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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverFootnote(at: convert(event.locationInWindow, from: nil))
    }

    required init?(coder: NSCoder) {
        fatalError("EditorTextView is built in code")
    }

    static func scrollView() -> NSScrollView {
        let textView = EditorTextView()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = textView.backgroundColor
        scrollView.documentView = textView
        let status = NSTextField(labelWithString: "")
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.textColor = ThemeStore.shared.color(.ink2)
        status.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(status)
        NSLayoutConstraint.activate([
            status.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8),
        ])
        status.isHidden = textView.vim == nil
        textView.vimStatus = status
        textView.vimDidRun()
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
        vimStatus?.textColor = store.color(.ink2)
        fitColumn(to: frame.width)
        if store.vimMode != (vim != nil) { vim = store.vimMode ? VimEngine() : nil }
    }

    @objc private func themeDidChange(_ notification: Notification) {
        applyTheme()
        styler.restyleDocument()
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
        drawCallouts(in: visible, line: line(at:))
        ThemeStore.shared.color(.quoteRule).setFill()
        storage.enumerateAttribute(.dewlineQuote, in: visible) { value, range, _ in
            guard value != nil else { return }
            let top = line(at: range.location)
            let bottom = line(at: max(NSMaxRange(range) - 1, range.location))
            NSRect(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: top.minY, width: 2, height: bottom.maxY - top.minY).fill()
        }
    }

    /// The text's children plus one image per rendered block, labeled with its source, and one checkbox per task box.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        let storage = textStorage!
        storage.enumerateAttribute(.dewlineBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            switch (value as? BlockLine)?.role {
            case .picture(let picture, let label)?:
                let line = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
                let frame = NSRect(x: line.minX, y: line.maxY - picture.size.height, width: picture.size.width, height: picture.size.height)
                children.append(NSAccessibilityElement.element(withRole: .image, frame: frame, label: label, parent: self))
            case .task(let task)?:
                let box = range.location + task.at
                let frame = firstRect(forCharacterRange: NSRange(location: box, length: 3), actualRange: nil)
                children.append(TaskBoxElement(frame: frame, label: task.label, checked: task.checked, parent: self) { [weak self] in
                    self?.toggleTask(at: box + 1)
                })
            default:
                break
            }
        }
        return children
    }

    /// Cmd-click follows a link, wikilink, embed, footnote or tag; a click on a task box toggles it and leaves the
    /// caret where it was.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), follow(at: point) { return }
        guard let box = taskBox(at: point) else { return super.mouseDown(with: event) }
        toggleTask(at: box)
    }

    /// With Vim on, keys outside insert mode go to Vim and never to the input method; marked text keeps its keys.
    override func keyDown(with event: NSEvent) {
        guard let vim, !hasMarkedText(), !event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
        let key = Self.vimKey(event)
        if vim.mode == .insert, key != "<Esc>" { return super.keyDown(with: event) }
        if let key { vim.handle(key, in: self) }
        vimDidRun()
    }

    private static func vimKey(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 53: return "<Esc>"
        case 36, 76: return "<CR>"
        case 51: return "<BS>"
        case 123: return "<Left>"
        case 124: return "<Right>"
        case 125: return "<Down>"
        case 126: return "<Up>"
        default: break
        }
        if event.modifierFlags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "r": return "<C-r>"
            case "[": return "<Esc>"
            default: return nil
            }
        }
        guard let characters = event.characters, characters.count == 1, let scalar = characters.unicodeScalars.first,
            scalar.value >= 32, scalar.value != 127, !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return characters
    }

    func vimDidRun() {
        blockCaret = vim?.mode == .normal
        vimStatus?.stringValue = vim?.status ?? ""
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
        guard let layout = textLayoutManager else { return }
        let visible = visibleRect
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
    }

    /// The one-range form calls this one, and Find's replace calls only this one.
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let changes = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if changes, affectedRanges.count == 1, let string = replacementStrings?.first {
            styler.landing = affectedRanges[0].rangeValue.location + string.utf16.count
        } else {
            styler.landing = nil
        }
        return changes
    }

    override func didChangeText() {
        snapshot?.removeFromSuperview()
        super.didChangeText()
    }

    /// The baseline of the line holding the character at `index`, in this view's coordinates.
    func baseline(at index: Int) -> CGFloat? {
        guard index >= 0, index < textStorage!.length, let layout = textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: index)
        else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(offset, $0.characterRange) }) else { return nil }
        return textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleSource(_:)) else { return super.validateMenuItem(menuItem) }
        menuItem.state = styler.showsSource ? .on : .off
        return true
    }
}

extension EditorTextView: VimHost {
    var vimText: NSString { textStorage!.mutableString }

    var vimSelection: NSRange {
        get { selectedRange() }
        set {
            setSelectedRange(newValue)
            scrollRangeToVisible(newValue)
        }
    }

    var vimClipboard: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }

    /// Through shouldChangeText and didChangeText, as typing goes, so the styler, the change engine and undo see it.
    func vimReplace(_ range: NSRange, with string: String) {
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage!.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: styler.baseAttributes))
        didChangeText()
    }

    func vimUndo() {
        undoManager?.undo()
    }

    func vimRedo() {
        undoManager?.redo()
    }

    func vimSave() {
        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: self)
    }

    func vimClose() {
        window?.performClose(nil)
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
