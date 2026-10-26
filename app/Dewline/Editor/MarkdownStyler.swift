import AppKit

/// Styles markdown through attributes only and owns the editor's undo history.
@MainActor
final class MarkdownStyler: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    weak var textView: EditorTextView?
    let undoManager = UndoManager()
    let blocks = RenderedBlocks()
    private(set) var restyles = 0
    private(set) var showsSource = false
    /// Source line height: 22 pt, or prose's 24.5 pt pitch through `DewlineSourceLineHeight`, until the owner picks one.
    var sourceLineHeight: CGFloat = {
        let height = UserDefaults.standard.double(forKey: "DewlineSourceLineHeight")
        return height > 0 ? height : 22
    }()
    private var revealed: Set<SyntaxSpan> = []
    private var pending: NSRange?
    /// Where the caret lands after the edit `shouldChangeText` approved, until the storage processes that edit.
    var landing: Int?
    /// Text not styled yet, whole paragraphs, which `styleSome` works through from the top of the view.
    private var unstyled = IndexSet()
    private var scheduled = false

    var hasUnstyledText: Bool {
        !unstyled.isEmpty
    }

    static var bodyFont: NSFont {
        ThemeStore.shared.bodyFont
    }

    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    /// The attributes styling owns; restyling leaves every other attribute in the storage as it is.
    private static let keys = [
        NSAttributedString.Key.font, .foregroundColor, .backgroundColor, .paragraphStyle, .underlineStyle, .strikethroughStyle, .kern,
        .dewlineMarkerFont, .dewlineBlock, .dewlineQuote,
    ].map { $0.rawValue as NSString }
    /// The most text one pass styles while more waits: several screens, a few milliseconds of work.
    private static let chunk = 1 << 14
    private static var base: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: ThemeStore.shared.color(.ink),
            .paragraphStyle: ThemeStore.shared.paragraphStyle(lineHeight: ThemeStore.shared.bodyLineHeight),
            .underlineStyle: 0,
            .strikethroughStyle: 0,
        ]
    }

    /// The Code font slot at `font`'s x-height.
    static func code(matching font: NSFont) -> NSFont {
        let store = ThemeStore.shared
        return store.codeFont(size: font.pointSize * font.xHeight / store.codeFont(size: font.pointSize).xHeight)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        guard showsSource else { return Self.base }
        return Self.base.merging([
            .font: Self.code(matching: Self.bodyFont), .paragraphStyle: ThemeStore.shared.paragraphStyle(lineHeight: sourceLineHeight),
        ]) { $1 }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !textView!.defersStyling else { return }
        updateReveal()
    }

    /// Spelling and grammar marks skip code, math, front matter, addresses, wikilink targets and HTML tags.
    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0 else { return value }
        let text = textView.textStorage!.mutableString
        let literal = blocks.index.isCode(affectedCharRange, in: text)
            || SpikeTokenizer.literals(in: text, line: text.lineRange(for: affectedCharRange)).contains { NSIntersectionRange($0, affectedCharRange).length > 0 }
        return literal ? 0 : value
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        LatencyProbe.begin(.attributes)
        defer { LatencyProbe.end(.attributes) }
        MainActor.assumeIsolated {
            // A landing outside the edit is left from an approved edit that never came. Undo and redo come without
            // shouldChangeText and leave the caret at the end of the text they put back.
            let caret = landing.flatMap { editedRange.location <= $0 && $0 <= NSMaxRange(editedRange) ? $0 : nil }
                ?? (undoManager.isUndoing || undoManager.isRedoing ? NSMaxRange(editedRange) : nil)
            landing = nil
            let oldEnd = NSMaxRange(editedRange) - delta
            revealed = Set(revealed.compactMap { span in
                if NSMaxRange(span.range) < editedRange.location { return span }
                guard span.range.location > oldEnd else { return nil }
                return span.shifted(by: delta)
            })
            unstyled.remove(integersIn: editedRange.location..<oldEnd)
            unstyled.shift(startingAt: oldEnd, by: delta)
            var range = editedRange
            if let waiting = pending {
                func moved(_ offset: Int) -> Int {
                    offset < oldEnd ? min(offset, editedRange.location) : offset + delta
                }
                let start = moved(waiting.location)
                range = NSUnionRange(NSRange(location: start, length: moved(NSMaxRange(waiting)) - start), editedRange)
            }
            LatencyProbe.begin(.parse)
            let changed = blocks.textDidChange(textView!.textStorage!.mutableString, edited: editedRange, delta: delta)
            LatencyProbe.end(.parse)
            if textView!.defersStyling {
                pending = changed.reduce(range, NSUnionRange)
            } else {
                pending = nil
                // An edit made on the storage leaves the selection where it is unless the view moves it, and a move
                // updates the reveal.
                let selection = caret.map { [NSRange(location: $0, length: 0)] } ?? textView!.selectedRanges.map(\.rangeValue)
                restyleSoon(range, in: textView!.textStorage!, selection: selection)
                for block in changed where NSUnionRange(block, range) != range {
                    restyle(block, in: textView!.textStorage!, selection: selection)
                }
            }
        }
    }

    func flush() {
        if let range = pending {
            pending = nil
            restyle(range)
        }
        updateReveal()
        if !unstyled.isEmpty { schedule() }
    }

    /// Switches mode and restyles the paragraphs around `range`; `restyleDocument()` brings the rest along.
    func toggleSource(restyling range: NSRange) {
        showsSource.toggle()
        restyle(range)
    }

    func restyleDocument() {
        restyle(NSRange(location: 0, length: textView!.textStorage!.length))
    }

    /// Restyles `range`, or after the composition while an input method composes.
    func restyleNow(_ range: NSRange) {
        guard !textView!.defersStyling else {
            pending = pending.map { NSUnionRange($0, range) } ?? range
            return
        }
        restyle(range)
    }

    private func restyle(_ range: NSRange) {
        let storage = textView!.textStorage!
        storage.beginEditing()
        restyle(range, in: storage, selection: textView!.selectedRanges.map(\.rangeValue))
        storage.endEditing()
    }
}

extension MarkdownStyler {
    /// Restyles `range`, unless it is long and the view is at the top of the text, as when a document opens: then its
    /// first chunk, which covers the view, is styled now and the rest by `styleSome`.
    private func restyleSoon(_ range: NSRange, in storage: NSTextStorage, selection: [NSRange]) {
        let paragraphs = storage.mutableString.paragraphRange(for: range)
        guard paragraphs.length > Self.chunk, textView!.visibleRect.minY <= 0 else {
            return restyle(paragraphs, in: storage, selection: selection)
        }
        unstyled.insert(integersIn: Range(paragraphs)!)
        restyle(NSRange(location: paragraphs.location, length: Self.chunk), in: storage, selection: selection)
        schedule()
    }

    /// Runs `styleSome` on the main run loop's next pass, which comes after any event in hand and before the view
    /// displays. A block, unlike a timer, runs before the display that follows an event; unlike the main queue, it
    /// also runs in a run loop nested inside a main-queue job.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.styleSome() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Styles the next chunk of unstyled text in text order and schedules the next. Once the view is past the first
    /// unstyled character, the rest is styled in one pass: each chunk styled above the view would make TextKit 2 place
    /// the view again. That pass holds the caret's line, or the first visible line, in place, as switching to the
    /// source does.
    private func styleSome() {
        scheduled = false
        guard let textView, !textView.defersStyling, let first = unstyled.first else { return }
        let storage = textView.textStorage!
        let past = isPast(first)
        var held: (anchor: Int, offset: CGFloat)?
        if past {
            let visible = textView.visibleRect
            func index(_ x: CGFloat, _ y: CGFloat) -> Int {
                textView.characterIndexForInsertion(at: NSPoint(x: x, y: max(y, textView.textContainerOrigin.y)))
            }
            let top = index(visible.minX, visible.minY)
            let caret = textView.selectedRange().location
            let anchor = min(top <= caret && caret <= index(visible.maxX, visible.maxY) ? caret : top, storage.length - 1)
            held = textView.baseline(at: anchor).map { (anchor, $0 - visible.minY) }
        }
        let length = past ? storage.length - first : min(unstyled.rangeView.first!.count, Self.chunk)
        storage.beginEditing()
        restyle(NSRange(location: first, length: length), in: storage, selection: textView.selectedRanges.map(\.rangeValue))
        storage.endEditing()
        if let held { textView.hold(held.anchor, at: held.offset) }
        if !unstyled.isEmpty { schedule() }
    }

    /// Whether the top of the view is past the line holding `index`, found without laying out any text.
    private func isPast(_ index: Int) -> Bool {
        let textView = textView!
        let visible = textView.visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text.
        return index < textView.characterIndexForInsertion(at: NSPoint(x: visible.minX, y: max(visible.minY, textView.textContainerOrigin.y)))
    }

    private func restyle(_ range: NSRange, in storage: NSTextStorage, selection: [NSRange]) {
        restyles += 1
        let paragraphs = storage.mutableString.paragraphRange(for: range)
        unstyled.remove(integersIn: Range(paragraphs)!)
        let styled = NSMutableAttributedString(string: storage.mutableString.substring(with: paragraphs))
        let text = styled.mutableString
        let whole = NSRange(location: 0, length: styled.length)
        let source = showsSource
        let store = ThemeStore.shared
        styled.addAttributes(baseAttributes, range: whole)
        revealed = revealed.filter { !NSLocationInRange($0.range.location, paragraphs) }
        let selection = selection.map { NSRange(location: $0.location - paragraphs.location, length: $0.length) }
        text.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, line, paragraph, _ in
            guard !self.blocks.contains(NSRange(location: line.location + paragraphs.location, length: line.length)) else { return }
            LatencyProbe.begin(.parse)
            let spans = SpikeTokenizer.spans(in: text, line: line)
            LatencyProbe.end(.parse)
            for span in spans {
                switch span.kind {
                case .heading where source:
                    Self.add(.bold, in: paragraph, of: styled)
                    styled.addAttribute(.foregroundColor, value: store.color(.heading), range: paragraph)
                case .heading(let level):
                    let heading = store.heading(level)
                    styled.addAttributes([
                        .font: heading.font, .paragraphStyle: store.paragraphStyle(lineHeight: heading.lineHeight),
                        .foregroundColor: store.color(level < 5 ? .heading : .ink2),
                    ], range: paragraph)
                    if heading.kern != 0 { styled.addAttribute(.kern, value: heading.kern, range: paragraph) }
                case .quote where source:
                    break
                case .quote:
                    styled.addAttributes([.paragraphStyle: store.quoteParagraphStyle, .foregroundColor: store.color(.heading), .dewlineQuote: true], range: paragraph)
                    Self.add(.italic, in: span.content, of: styled)
                case .strong:
                    Self.add(.bold, in: span.content, of: styled)
                case .emphasis:
                    Self.add(.italic, in: span.content, of: styled)
                case .strikethrough:
                    styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
                case .link:
                    styled.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: store.color(.link)], range: span.content)
                case .inlineCode where source:
                    break
                case .inlineCode:
                    styled.enumerateAttribute(.font, in: span.content) { value, run, _ in
                        styled.addAttribute(.font, value: Self.code(matching: value as! NSFont), range: run)
                    }
                    styled.addAttribute(.backgroundColor, value: store.color(.codeBackground), range: span.range)
                }
            }
            for span in spans {
                for marker in span.markers {
                    styled.addAttribute(.dewlineMarkerFont, value: styled.attribute(.font, at: marker.location, effectiveRange: nil)!, range: marker)
                }
                let reveal = Self.touches(span, selection)
                if reveal { self.revealed.insert(span.shifted(by: paragraphs.location)) }
                self.mark(span, revealed: reveal || source, in: styled)
            }
        }
        blocks.style(styled, at: paragraphs.location, selection: source ? [whole] : selection)
        // Only runs whose styling differs are written, once each, so layout invalidates only what changed. The CF
        // accessors return a run's dictionary without bridging it to Swift, which costs more than the comparison.
        var offset = 0
        while offset < whole.length {
            var run = CFRange()
            let wanted = CFAttributedStringGetAttributes(styled, offset, &run) as NSDictionary
            let end = paragraphs.location + run.location + run.length
            var location = paragraphs.location + offset
            while location < end {
                var part = CFRange()
                let current = CFAttributedStringGetAttributes(storage, location, &part) as NSDictionary
                let length = min(part.location + part.length, end) - location
                if Self.keys.contains(where: { wanted.object(forKey: $0) as? NSObject != current.object(forKey: $0) as? NSObject }) {
                    let merged = current.mutableCopy() as! NSMutableDictionary
                    for key in Self.keys {
                        if let value = wanted.object(forKey: key) {
                            merged.setObject(value, forKey: key)
                        } else {
                            merged.removeObject(forKey: key)
                        }
                    }
                    CFAttributedStringSetAttributes(storage, CFRange(location: location, length: length), merged, true)
                }
                location += length
            }
            offset = run.location + run.length
        }
    }

    private func mark(_ span: SyntaxSpan, revealed: Bool, in storage: NSMutableAttributedString) {
        for marker in span.markers {
            if revealed {
                let font = storage.attribute(.dewlineMarkerFont, at: marker.location, effectiveRange: nil)!
                storage.addAttributes([.font: font, .foregroundColor: ThemeStore.shared.color(showsSource ? .ink2 : .syntax)], range: marker)
            } else {
                storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: marker)
            }
        }
    }

    private func updateReveal() {
        LatencyProbe.begin(.reveal)
        defer { LatencyProbe.end(.reveal) }
        guard !showsSource else { return }
        let textView = textView!
        let storage = textView.textStorage!
        let text = storage.mutableString
        let selection = textView.selectedRanges.map(\.rangeValue)
        var now: Set<SyntaxSpan> = []
        for range in selection {
            text.enumerateSubstrings(in: text.paragraphRange(for: range), options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
                guard !self.blocks.contains(line) else { return }
                // Unstyled text takes the selection's reveal state when it is styled.
                guard !self.unstyled.intersects(integersIn: Range(line)!) else { return }
                now.formUnion(SpikeTokenizer.spans(in: text, line: line).filter { Self.touches($0, selection) })
            }
        }
        let hide = revealed.subtracting(now)
        let show = now.subtracting(revealed)
        revealed = now
        let changedBlocks = blocks.revealChanges(selection)
        guard !hide.isEmpty || !show.isEmpty || !changedBlocks.isEmpty else { return }
        storage.beginEditing()
        // In document order, the storage's attribute writes stay linear in the span count.
        for span in hide.sorted(by: { $0.range.location < $1.range.location }) { mark(span, revealed: false, in: storage) }
        for span in show.sorted(by: { $0.range.location < $1.range.location }) { mark(span, revealed: true, in: storage) }
        for range in changedBlocks { restyle(range, in: storage, selection: selection) }
        storage.endEditing()
    }

    private static func touches(_ span: SyntaxSpan, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(span.range) && NSMaxRange($0) >= span.range.location }
    }

    private static func add(_ traits: NSFontDescriptor.SymbolicTraits, in range: NSRange, of storage: NSMutableAttributedString) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            storage.addAttribute(.font, value: ThemeStore.shared.font(value as! NSFont, adding: traits), range: run)
        }
    }
}

extension NSAttributedString.Key {
    static let dewlineMarkerFont = NSAttributedString.Key("DewlineMarkerFont")
}
