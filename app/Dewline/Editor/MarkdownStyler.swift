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

    static let bodyFont = serif(size: 17, traits: [])
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    private static let base: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: lines(24.5),
        .underlineStyle: 0,
        .strikethroughStyle: 0,
    ]

    /// The Code font slot (the face `DewlineCodeFont` names, else the bundled JetBrains Mono) at `font`'s x-height.
    static func code(matching font: NSFont) -> NSFont {
        func face(_ size: CGFloat) -> NSFont {
            NSFont(name: UserDefaults.standard.string(forKey: "DewlineCodeFont") ?? "JetBrainsMono-Regular", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return face(font.pointSize * font.xHeight / face(font.pointSize).xHeight)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        guard showsSource else { return Self.base }
        return Self.base.merging([.font: Self.code(matching: Self.bodyFont), .paragraphStyle: Self.lines(sourceLineHeight)]) { $1 }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !textView!.defersStyling else { return }
        updateReveal()
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            let oldEnd = NSMaxRange(editedRange) - delta
            revealed = Set(revealed.compactMap { span in
                if NSMaxRange(span.range) < editedRange.location { return span }
                guard span.range.location > oldEnd else { return nil }
                return span.shifted(by: delta)
            })
            var range = editedRange
            if let waiting = pending {
                func moved(_ offset: Int) -> Int {
                    offset < oldEnd ? min(offset, editedRange.location) : offset + delta
                }
                let start = moved(waiting.location)
                range = NSUnionRange(NSRange(location: start, length: moved(NSMaxRange(waiting)) - start), editedRange)
            }
            let changed = blocks.textDidChange(textView!.textStorage!.mutableString, edited: editedRange, delta: delta)
            if textView!.defersStyling {
                pending = changed.reduce(range, NSUnionRange)
            } else {
                pending = nil
                let selection = [NSRange(location: NSMaxRange(editedRange), length: 0)]
                restyle(range, in: textView!.textStorage!, selection: selection)
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
    private func restyle(_ range: NSRange, in storage: NSTextStorage, selection: [NSRange]) {
        restyles += 1
        let paragraphs = storage.mutableString.paragraphRange(for: range)
        let styled = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraphs))
        let text = styled.mutableString
        let whole = NSRange(location: 0, length: styled.length)
        let source = showsSource
        styled.addAttributes(baseAttributes, range: whole)
        styled.removeAttribute(.dewlineHidden, range: whole)
        styled.removeAttribute(.dewlineMarkerFont, range: whole)
        revealed = revealed.filter { !NSLocationInRange($0.range.location, paragraphs) }
        let selection = selection.map { NSRange(location: $0.location - paragraphs.location, length: $0.length) }
        text.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, line, paragraph, _ in
            guard !self.blocks.contains(NSRange(location: line.location + paragraphs.location, length: line.length)) else { return }
            let spans = SpikeTokenizer.spans(in: text, line: line)
            for span in spans {
                switch span.kind {
                case .heading where source:
                    Self.add(.bold, in: paragraph, of: styled)
                case .heading(let level):
                    let font = Self.serif(size: [28, 23, 20, 19, 18, 17.5][level - 1], traits: .bold)
                    styled.addAttributes([.font: font, .paragraphStyle: Self.lines(font.pointSize / 17 * 24.5)], range: paragraph)
                case .strong:
                    Self.add(.bold, in: span.content, of: styled)
                case .emphasis:
                    Self.add(.italic, in: span.content, of: styled)
                case .strikethrough:
                    styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
                case .link:
                    styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
                case .inlineCode where source:
                    break
                case .inlineCode:
                    styled.enumerateAttribute(.font, in: span.content) { value, run, _ in
                        styled.addAttribute(.font, value: Self.code(matching: value as! NSFont), range: run)
                    }
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
        // Only attributes that differ are written, so layout invalidates only what changed.
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .paragraphStyle, .underlineStyle, .strikethroughStyle, .dewlineHidden, .dewlineMarkerFont, .dewlineBlock]
        styled.enumerateAttributes(in: whole) { wanted, run, _ in
            storage.enumerateAttributes(in: NSRange(location: run.location + paragraphs.location, length: run.length)) { current, part, _ in
                for key in keys where wanted[key] as? NSObject != current[key] as? NSObject {
                    if let value = wanted[key] {
                        storage.addAttribute(key, value: value, range: part)
                    } else {
                        storage.removeAttribute(key, range: part)
                    }
                }
            }
        }
    }

    private func mark(_ span: SyntaxSpan, revealed: Bool, in storage: NSMutableAttributedString) {
        for marker in span.markers {
            if revealed {
                let font = storage.attribute(.dewlineMarkerFont, at: marker.location, effectiveRange: nil)!
                storage.addAttributes([.font: font, .foregroundColor: showsSource ? NSColor.secondaryLabelColor : .tertiaryLabelColor], range: marker)
                storage.removeAttribute(.dewlineHidden, range: marker)
            } else if textView!.textLayoutManager == nil {
                storage.addAttributes([.dewlineHidden: true, .foregroundColor: NSColor.clear], range: marker)
            } else {
                storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: marker)
            }
        }
    }

    private func updateReveal() {
        guard !showsSource else { return }
        let textView = textView!
        let storage = textView.textStorage!
        let text = storage.mutableString
        let selection = textView.selectedRanges.map(\.rangeValue)
        var now: Set<SyntaxSpan> = []
        for range in selection {
            text.enumerateSubstrings(in: text.paragraphRange(for: range), options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
                guard !self.blocks.contains(line) else { return }
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
            let font = value as! NSFont
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
            storage.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize)!, range: run)
        }
    }

    private static func serif(size: CGFloat, traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)!.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size)!
    }

    private static func lines(_ height: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }
}
