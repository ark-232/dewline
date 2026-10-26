import AppKit

/// Styles markdown through attributes only and owns the editor's undo history.
@MainActor
final class MarkdownStyler: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    weak var textView: EditorTextView?
    let undoManager = UndoManager()
    private(set) var paragraphRestyles = 0
    private var revealed: [SyntaxSpan] = []
    private var pending: NSRange?

    static let bodyFont = serif(size: 17, traits: [])
    private static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    private static let base: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: lines(of: 17),
        .underlineStyle: 0,
        .strikethroughStyle: 0,
    ]

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView, !textView.defersStyling else { return }
        updateReveal()
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard let textView, let storage = textView.textStorage else { return }
            let oldEnd = NSMaxRange(editedRange) - delta
            revealed = revealed.compactMap { span in
                if NSMaxRange(span.range) < editedRange.location { return span }
                guard span.range.location > oldEnd else { return nil }
                return span.shifted(by: delta)
            }
            var range = editedRange
            if var waiting = pending {
                if waiting.location >= oldEnd {
                    waiting.location += delta
                } else if NSMaxRange(waiting) > editedRange.location {
                    waiting.length = max(0, waiting.length + delta)
                }
                range = NSUnionRange(waiting, editedRange)
            }
            if textView.defersStyling {
                pending = range
            } else {
                pending = nil
                restyle(range, in: storage)
            }
        }
    }

    func flush() {
        guard let textView, let storage = textView.textStorage else { return }
        if let range = pending {
            pending = nil
            let length = storage.length
            let start = min(range.location, length)
            storage.beginEditing()
            restyle(NSRange(location: start, length: min(NSMaxRange(range), length) - start), in: storage)
            storage.endEditing()
        }
        updateReveal()
    }
}

extension MarkdownStyler {
    private func restyle(_ range: NSRange, in storage: NSTextStorage) {
        paragraphRestyles += 1
        let paragraphs = storage.mutableString.paragraphRange(for: range)
        let styled = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraphs))
        let text = styled.mutableString
        let whole = NSRange(location: 0, length: styled.length)
        styled.addAttributes(Self.base, range: whole)
        styled.removeAttribute(.dewlineHidden, range: whole)
        styled.removeAttribute(.dewlineMarkerFont, range: whole)
        revealed.removeAll { NSLocationInRange($0.range.location, paragraphs) }
        let selection = (textView?.selectedRanges ?? []).map { NSRange(location: $0.rangeValue.location - paragraphs.location, length: $0.rangeValue.length) }
        text.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, line, paragraph, _ in
            let spans = SpikeTokenizer.spans(in: text, line: line)
            for span in spans {
                self.style(span, paragraph: paragraph, in: styled)
            }
            for span in spans {
                for marker in span.markers {
                    styled.addAttribute(.dewlineMarkerFont, value: styled.attribute(.font, at: marker.location, effectiveRange: nil)!, range: marker)
                }
                let reveal = Self.touches(span, selection)
                if reveal { self.revealed.append(span.shifted(by: paragraphs.location)) }
                self.mark(span, revealed: reveal, in: styled)
            }
        }
        Self.apply(styled, at: paragraphs.location, to: storage)
    }

    /// Writes only the attributes that differ, so the processed range stays the edit and AppKit keeps the spelling marks beside it.
    private static func apply(_ styled: NSAttributedString, at offset: Int, to storage: NSTextStorage) {
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .paragraphStyle, .underlineStyle, .strikethroughStyle, .dewlineHidden, .dewlineMarkerFont]
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { wanted, run, _ in
            storage.enumerateAttributes(in: NSRange(location: run.location + offset, length: run.length)) { current, part, _ in
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

    private func style(_ span: SyntaxSpan, paragraph: NSRange, in storage: NSMutableAttributedString) {
        switch span.kind {
        case .heading(let level):
            let font = Self.serif(size: [28, 23, 20, 17, 17, 17][level - 1], traits: .bold)
            storage.addAttributes([.font: font, .paragraphStyle: Self.lines(of: font.pointSize)], range: paragraph)
        case .strong:
            Self.add(.bold, in: span.content, of: storage)
        case .emphasis:
            Self.add(.italic, in: span.content, of: storage)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
        case .link:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
        case .inlineCode:
            storage.enumerateAttribute(.font, in: span.content) { value, run, _ in
                let size = (value as! NSFont).pointSize * 0.88
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), range: run)
            }
        }
    }

    private func mark(_ span: SyntaxSpan, revealed: Bool, in storage: NSMutableAttributedString) {
        for marker in span.markers {
            if revealed {
                let font = storage.attribute(.dewlineMarkerFont, at: marker.location, effectiveRange: nil)!
                storage.addAttributes([.font: font, .foregroundColor: NSColor.tertiaryLabelColor], range: marker)
                storage.removeAttribute(.dewlineHidden, range: marker)
            } else if textView?.textLayoutManager == nil {
                storage.addAttributes([.dewlineHidden: true, .foregroundColor: NSColor.clear], range: marker)
            } else {
                storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: marker)
            }
        }
    }

    private func updateReveal() {
        guard let textView, let storage = textView.textStorage else { return }
        let text = storage.mutableString
        let selection = textView.selectedRanges.map(\.rangeValue)
        var now: [SyntaxSpan] = []
        for range in selection {
            text.enumerateSubstrings(in: text.paragraphRange(for: range), options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
                for span in SpikeTokenizer.spans(in: text, line: line) where Self.touches(span, selection) && !now.contains(span) {
                    now.append(span)
                }
            }
        }
        let hide = revealed.filter { !now.contains($0) }
        let show = now.filter { !revealed.contains($0) }
        revealed = now
        guard !hide.isEmpty || !show.isEmpty else { return }
        storage.beginEditing()
        for span in hide { mark(span, revealed: false, in: storage) }
        for span in show { mark(span, revealed: true, in: storage) }
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

    private static func lines(of size: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = size / 17 * 24.5
        style.maximumLineHeight = style.minimumLineHeight
        return style
    }
}
