import AppKit

/// Styles markdown through attributes only and owns the editor's undo history.
@MainActor
final class MarkdownStyler: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    weak var textView: EditorTextView?
    let undoManager = UndoManager()
    private(set) var restyles = 0
    private var revealed: Set<SyntaxSpan> = []
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
            if textView!.defersStyling {
                pending = range
            } else {
                pending = nil
                restyle(range, in: textView!.textStorage!, selection: [NSRange(location: NSMaxRange(editedRange), length: 0)])
            }
        }
    }

    func flush() {
        if let range = pending {
            pending = nil
            let storage = textView!.textStorage!
            storage.beginEditing()
            restyle(range, in: storage, selection: textView!.selectedRanges.map(\.rangeValue))
            storage.endEditing()
        }
        updateReveal()
    }
}

extension MarkdownStyler {
    private func restyle(_ range: NSRange, in storage: NSTextStorage, selection: [NSRange]) {
        restyles += 1
        let paragraphs = storage.mutableString.paragraphRange(for: range)
        let styled = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraphs))
        let text = styled.mutableString
        let whole = NSRange(location: 0, length: styled.length)
        styled.addAttributes(Self.base, range: whole)
        styled.removeAttribute(.dewlineHidden, range: whole)
        styled.removeAttribute(.dewlineMarkerFont, range: whole)
        revealed = revealed.filter { !NSLocationInRange($0.range.location, paragraphs) }
        let selection = selection.map { NSRange(location: $0.location - paragraphs.location, length: $0.length) }
        text.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, line, paragraph, _ in
            let spans = SpikeTokenizer.spans(in: text, line: line)
            for span in spans {
                switch span.kind {
                case .heading(let level):
                    let font = Self.serif(size: [28, 23, 20, 19, 18, 17.5][level - 1], traits: .bold)
                    styled.addAttributes([.font: font, .paragraphStyle: Self.lines(of: font.pointSize)], range: paragraph)
                case .strong:
                    Self.add(.bold, in: span.content, of: styled)
                case .emphasis:
                    Self.add(.italic, in: span.content, of: styled)
                case .strikethrough:
                    styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
                case .link:
                    styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
                case .inlineCode:
                    styled.enumerateAttribute(.font, in: span.content) { value, run, _ in
                        let size = (value as! NSFont).pointSize * 0.88
                        styled.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), range: run)
                    }
                }
            }
            for span in spans {
                for marker in span.markers {
                    styled.addAttribute(.dewlineMarkerFont, value: styled.attribute(.font, at: marker.location, effectiveRange: nil)!, range: marker)
                }
                let reveal = Self.touches(span, selection)
                if reveal { self.revealed.insert(span.shifted(by: paragraphs.location)) }
                self.mark(span, revealed: reveal, in: styled)
            }
        }
        // Only attributes that differ are written, so layout invalidates only what changed.
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .paragraphStyle, .underlineStyle, .strikethroughStyle, .dewlineHidden, .dewlineMarkerFont]
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
                storage.addAttributes([.font: font, .foregroundColor: NSColor.tertiaryLabelColor], range: marker)
                storage.removeAttribute(.dewlineHidden, range: marker)
            } else if textView!.textLayoutManager == nil {
                storage.addAttributes([.dewlineHidden: true, .foregroundColor: NSColor.clear], range: marker)
            } else {
                storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: marker)
            }
        }
    }

    private func updateReveal() {
        let textView = textView!
        let storage = textView.textStorage!
        let text = storage.mutableString
        let selection = textView.selectedRanges.map(\.rangeValue)
        var now: Set<SyntaxSpan> = []
        for range in selection {
            text.enumerateSubstrings(in: text.paragraphRange(for: range), options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
                now.formUnion(SpikeTokenizer.spans(in: text, line: line).filter { Self.touches($0, selection) })
            }
        }
        let hide = revealed.subtracting(now)
        let show = now.subtracting(revealed)
        revealed = now
        guard !hide.isEmpty || !show.isEmpty else { return }
        storage.beginEditing()
        // In document order, the storage's attribute writes stay linear in the span count.
        for span in hide.sorted(by: { $0.range.location < $1.range.location }) { mark(span, revealed: false, in: storage) }
        for span in show.sorted(by: { $0.range.location < $1.range.location }) { mark(span, revealed: true, in: storage) }
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
