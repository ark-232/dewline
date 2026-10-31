import AppKit

/// The markdown editor: hides syntax through `MarkdownStyler` and defers styling while an input method composes.
final class EditorTextView: CaretTextView {
    let styler = MarkdownStyler()
    /// The change engine's marks, painted under the text.
    let marks = ChangeMarks()
    /// Your edits' undo history, which landings move instead of clearing.
    lazy var history = UndoHistory(undoManager: styler.undoManager)
    private let blockFragments = BlockFragments()
    private var composing = false
    private var toggleWaits = false
    private var held: (anchor: Int, offset: CGFloat)?
    private weak var snapshot: NSView?
    /// When the last toggle committed its first frame and started the fade.
    private(set) var fadeStarted: ContinuousClock.Instant?
    /// Where images in the document resolve from, and where pasted images go; nil until the document is saved.
    var documentFolder: URL?
    /// Vim's keys, while Vim mode is on.
    var vim: VimEngine? {
        didSet {
            vimStatus?.isHidden = vim == nil
            vimDidRun()
        }
    }
    private var vimStatus: NSTextField?
    /// The foldable block under the pointer, by its location.
    private(set) var hoveredFold: Int?
    private var centering = false
    private var dimmed = false
    /// Focus dims every block but the caret's.
    var focusMode = false {
        didSet { updateFocus() }
    }
    /// Typewriter keeps the caret's line in the middle of the view.
    var typewriterMode = false {
        didSet {
            fitColumn(to: frame.width)
            centerCaretSoon()
        }
    }
    /// Where wikilinks resolve: the window's folder, else the document's.
    var noteFolder: URL?
    /// Opens a note a link points to, at a heading.
    var openNote: ((URL, String?) -> Void)?
    /// Runs Find in Files for a tag; a window without a folder has none, and Cmd-clicking a tag beeps.
    var findInFiles: ((String) -> Void)?
    var footnotePopover: NSPopover?
    /// Counts the storage's character edits; the change engine stamps landings and saves with it.
    private(set) var version: UInt64 = 0
    /// Called after each character edit with its range and change in length.
    var edited: ((NSRange, Int) -> Void)?
    /// Called when a composition or a Writing Tools session ends.
    var inputEnded: (() -> Void)?

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
        styler.highlights.textView = self
        textLayoutManager?.renderingAttributesValidator = { [weak self] layout, fragment in
            MainActor.assumeIsolated { self?.styler.highlights.validate(layout, fragment) }
        }
        history.textView = self
        delegate = styler
        textStorage?.delegate = styler
        isRichText = false
        // The history records edits itself, so a landing can move them.
        allowsUndo = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = true
        usesFindBar = true
        marks.textView = self
        marks.autoresizingMask = [.width, .height]
        marks.wantsLayer = true
        addSubview(marks, positioned: .below, relativeTo: nil)
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: ThemeStore.didChange, object: nil)
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
        isAutomaticQuoteSubstitutionEnabled = store.smartPunctuation
        isAutomaticDashSubstitutionEnabled = store.smartPunctuation
        fitColumn(to: frame.width)
        if store.vimMode != (vim != nil) { vim = store.vimMode ? VimEngine() : nil }
        updateFocus()
    }

    @objc private func themeDidChange(_ notification: Notification) {
        applyTheme()
        styler.restyleDocument()
        styler.highlights.recolor()
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

    /// Centers the column at the measure, with margins of at least 32 pt; a narrower view fills. Typewriter lets the
    /// first and last lines scroll to the middle.
    private func fitColumn(to width: CGFloat) {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let margin = max(32, ((width - ThemeStore.shared.measure) / 2 - padding).rounded(.down))
        let height = typewriterMode ? max(24, ((enclosingScrollView?.contentView.bounds.height ?? 0) / 2).rounded()) : 24
        if textContainerInset != NSSize(width: margin, height: height) {
            textContainerInset = NSSize(width: margin, height: height)
        }
    }

    /// Draws the fold disclosures and each quote's rule at the column's left edge.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawDisclosures(in: rect)
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
        // A composition is one undo entry, from its first marked text to its commit.
        if !hasMarkedText() { history.breakCoalescing() }
        composing = true
        history.composing = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composing = false
        if !hasMarkedText() { compositionEnded() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let commits = hasMarkedText()
        composing = commits
        history.typing = true
        super.insertText(string, replacementRange: replacementRange)
        history.typing = false
        composing = false
        if commits { compositionEnded() }
    }

    override func unmarkText() {
        composing = true
        super.unmarkText()
        composing = false
        compositionEnded()
    }

    /// Keys that edit, such as Delete, coalesce with typing.
    override func doCommand(by selector: Selector) {
        let before = version
        history.typing = true
        super.doCommand(by: selector)
        history.typing = false
        // A key that moves the caret ends the typing.
        if version == before { history.breakCoalescing() }
    }

    override func breakUndoCoalescing() {
        super.breakUndoCoalescing()
        history.breakCoalescing()
    }

    override func cut(_ sender: Any?) {
        history.perform("Cut") { super.cut(sender) }
    }

    override func paste(_ sender: Any?) {
        history.perform("Paste") { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        history.perform("Paste") { super.pasteAsPlainText(sender) }
    }

    override func layout() {
        super.layout()
        marks.layoutIfDirty()
    }

    /// Cmd-Return.
    @objc func keepChange(_ sender: Any?) {
        marks.keepAtCaret()
    }

    /// Option-Cmd-Delete.
    @objc func revertChange(_ sender: Any?) {
        marks.revertAtCaret()
    }

    func storageDidEdit(_ range: NSRange, delta: Int) {
        version += 1
        history.didEdit(range, delta: delta)
        edited?(range, delta)
    }

    private func compositionEnded() {
        history.composing = false
        history.breakCoalescing()
        styler.flush()
        inputEnded?()
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
        if changes, let replacementStrings {
            history.willEdit(affectedRanges.map(\.rangeValue), with: replacementStrings)
        }
        if changes, affectedRanges.count == 1, let string = replacementStrings?.first {
            styler.landing = affectedRanges[0].rangeValue.location + string.utf16.count
        } else {
            styler.landing = nil
        }
        return changes
    }

    override func didChangeText() {
        history.didChangeText()
        snapshot?.removeFromSuperview()
        super.didChangeText()
        updateFocus()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        marks.caretMoved()
        guard !stillSelecting else { return }
        updateFocus()
        centerCaretSoon()
    }

    override func insertNewline(_ sender: Any?) {
        guard hasMarkedText() || !continueList() else { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        guard hasMarkedText() || !indentItems(outdent: false) else { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        guard hasMarkedText() || !indentItems(outdent: true) else { return }
        super.insertBacktab(sender)
    }

    /// Dims, by color alone, the text outside the caret's block, without touching the storage.
    private func updateFocus() {
        guard focusMode || dimmed, let layout = textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
        dimmed = false
        let length = textStorage?.length ?? 0
        guard focusMode, length > 0 else { return }
        dimmed = true
        let caret = selectedRange().location
        let focus = styler.map.blocks(in: NSRange(location: caret, length: 0)).first?.range
            ?? textStorage!.mutableString.paragraphRange(for: NSRange(location: min(caret, length), length: 0))
        let dim = ThemeStore.shared.color(.syntax)
        for part in [NSRange(location: 0, length: focus.location), NSRange(location: NSMaxRange(focus), length: length - NSMaxRange(focus))] where part.length > 0 {
            guard let start = content.location(content.documentRange.location, offsetBy: part.location),
                let end = content.location(start, offsetBy: part.length), let range = NSTextRange(location: start, end: end)
            else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: dim, for: range)
        }
    }

    /// Centers the caret's line after the event in hand has laid the text out. The view snaps there: edits and caret
    /// moves never animate, so Reduce Motion needs no other path.
    private func centerCaretSoon() {
        guard typewriterMode, !centering else { return }
        centering = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.centering = false
                let length = self.textStorage!.length
                guard self.typewriterMode, length > 0 else { return }
                self.hold(min(self.selectedRange().location, length - 1), at: self.visibleRect.height / 2 + MarkdownStyler.bodyFont.capHeight / 2)
            }
        }
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        focusMode.toggle()
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        typewriterMode.toggle()
    }

    @objc func toggleSmartPunctuation(_ sender: Any?) {
        ThemeStore.shared.smartPunctuation.toggle()
    }

    /// Cmd-click follows a link, wikilink, embed, footnote or tag. A click in the margin beside a foldable block folds or
    /// unfolds it; a click on a task box toggles it and leaves the caret where it was.
    override func mouseDown(with event: NSEvent) {
        history.breakCoalescing()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), follow(at: point) { return }
        if let box = taskBox(at: point) { return toggleTask(at: box) }
        guard point.x < textContainerOrigin.x, let (block, _) = foldable(at: point) else { return super.mouseDown(with: event) }
        let anchor = NSMaxRange(textStorage!.mutableString.lineRange(for: NSRange(location: block.range.location, length: 0)))
        if styler.folds.contains(where: { $0.location == anchor }) {
            styler.setFolds(styler.folds.filter { $0.location != anchor })
        } else {
            fold(block)
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["fold"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["fold": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverFootnote(at: point)
        let hovered = point.x < textContainerOrigin.x + (textContainer?.size.width ?? 0) ? foldable(at: point)?.block.range.location : nil
        guard hovered != hoveredFold else { return }
        hoveredFold = hovered
        setNeedsDisplay(NSRect(x: 0, y: visibleRect.minY, width: textContainerOrigin.x, height: visibleRect.height))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hoveredFold != nil else { return }
        hoveredFold = nil
        setNeedsDisplay(NSRect(x: 0, y: visibleRect.minY, width: textContainerOrigin.x, height: visibleRect.height))
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL].filter { !super.readablePasteboardTypes.contains($0) }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        insertImages(from: pboard) || super.readSelection(from: pboard, type: type)
    }

    /// Replaces `range` with `text` as one undoable edit of its own, named `name` in the Edit menu.
    func replaceAsOneEdit(_ range: NSRange, with text: String, named name: String = "") {
        history.perform(name) {
            guard shouldChangeText(in: range, replacementString: text) else { return }
            textStorage!.replaceCharacters(in: range, with: text)
            didChangeText()
        }
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

    /// Runs the `MarkdownFormat` command in the sender's tag as one undoable edit named for it.
    @objc func format(_ sender: Any?) {
        guard !hasMarkedText(), let command = (sender as? NSMenuItem).flatMap({ MarkdownFormat(rawValue: $0.tag) }),
            let edit = command.edit(in: textStorage!.mutableString, selection: selectedRange())
        else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage!.replaceCharacters(in: edit.range, with: edit.replacement)
        setSelectedRange(edit.selection)
        didChangeText()
        undoManager?.setActionName(command.name)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(format(_:)) { return isEditable }
        if menuItem.action == #selector(keepChange(_:)) || menuItem.action == #selector(revertChange(_:)) {
            return marks.changeAtCaret != nil
        }
        switch menuItem.action {
        case #selector(toggleSource(_:)): menuItem.state = styler.showsSource ? .on : .off
        case #selector(toggleFocusMode(_:)): menuItem.state = focusMode ? .on : .off
        case #selector(toggleTypewriterMode(_:)): menuItem.state = typewriterMode ? .on : .off
        case #selector(toggleSmartPunctuation(_:)): menuItem.state = ThemeStore.shared.smartPunctuation ? .on : .off
        case #selector(unfoldBlock(_:)), #selector(unfoldAll(_:)): return !styler.folds.isEmpty
        default: return super.validateMenuItem(menuItem)
        }
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
