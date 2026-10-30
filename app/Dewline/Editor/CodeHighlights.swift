import AppKit
import MdCore
import Synchronization

/// Colors fenced code by its language (record 0008). `core::highlight` finds the spans off the main thread, and the
/// colors go on as TextKit 2 rendering attributes, which redraw without layout. A block whose language has no syntax
/// stays plain monospace.
@MainActor
final class CodeHighlights {
    weak var textView: EditorTextView?

    private struct Entry {
        let id: UInt64
        /// The code between the fences.
        var range: NSRange
        var language: String
        /// The code the last request was for.
        var text: String
        /// In offsets from `range.location`, in order.
        var spans: [CodeSpan]
    }

    /// In text order.
    private var entries: [Entry] = []
    private static var lastID: UInt64 = 0
    /// One worker for the app.
    private nonisolated static let highlighter = Bundle.main.url(forResource: "Syntaxes", withExtension: "packdump").map(CodeHighlighter.init)
    /// The code each block's newest request is for, so requests an edit overtook skip the worker.
    private nonisolated static let wanted = Mutex<[UInt64: String]>([:])
    private let queue = DispatchQueue(label: "dev.arkwerx.dewline.highlight", qos: .userInitiated)

    /// Moves the entries past an edit. An edit inside a block's code keeps the spans it missed until the new ones come.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        entries = entries.compactMap { entry in
            var entry = entry
            if NSMaxRange(entry.range) <= edited.location, entry.range.length > 0 { return entry }
            if edited.location < entry.range.location, oldEnd <= entry.range.location {
                entry.range.location += delta
                return entry
            }
            guard entry.range.location <= edited.location, oldEnd <= NSMaxRange(entry.range) else {
                forget(entry)
                return nil
            }
            let (start, end) = (edited.location - entry.range.location, oldEnd - entry.range.location)
            entry.range.length += delta
            entry.spans = entry.spans.compactMap { span in
                if NSMaxRange(span.range) <= start { return span }
                guard span.range.location >= end else { return nil }
                return CodeSpan(range: NSRange(location: span.range.location + delta, length: span.range.length), codeClass: span.codeClass)
            }
            return entry
        }
    }

    /// Matches the entries in `paragraphs` to the fenced blocks there, and asks for the spans of code that changed.
    func update(_ blocks: [BlockMap.Block], in paragraphs: NSRange, text: NSString) {
        var seen = Set<UInt64>()
        for block in blocks {
            for span in block.spans where span.kind == .fencedCode && span.content.length > 0 {
                let range = NSRange(location: block.range.location + span.content.location, length: span.content.length)
                let fence = NSRange(location: block.range.location + span.range.location, length: span.content.location - span.range.location)
                let language = Self.language(text.substring(with: fence))
                guard !language.isEmpty else { continue }
                let code = text.substring(with: range)
                let index = entries.firstIndex { NSIntersectionRange($0.range, range).length > 0 || $0.range.location == range.location }
                if let index, entries[index].text == code, entries[index].language == language {
                    entries[index].range = range
                    seen.insert(entries[index].id)
                    continue
                }
                var entry: Entry
                if let index {
                    entry = entries.remove(at: index)
                    if entry.language != language { entry.spans = [] }
                    (entry.range, entry.language, entry.text) = (range, language, code)
                } else {
                    Self.lastID += 1
                    entry = Entry(id: Self.lastID, range: range, language: language, text: code, spans: [])
                }
                entries.insert(entry, at: entries.firstIndex { $0.range.location > range.location } ?? entries.endIndex)
                seen.insert(entry.id)
                request(entry)
            }
        }
        entries.removeAll { entry in
            let gone = NSIntersectionRange(entry.range, paragraphs).length > 0 && !seen.contains(entry.id)
            if gone { forget(entry) }
            return gone
        }
    }

    /// Recolors every block, as after a theme change.
    func recolor() {
        guard let layout = textView?.textLayoutManager, let content = layout.textContentManager else { return }
        layout.invalidateRenderingAttributes(for: content.documentRange)
    }

    /// Sets the colors of the code in `fragment`: the layout manager's rendering-attributes validator.
    func validate(_ layout: NSTextLayoutManager, _ fragment: NSTextLayoutFragment) {
        guard let content = layout.textContentManager else { return }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let range = NSRange(location: start, length: content.offset(from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation))
        layout.removeRenderingAttribute(.foregroundColor, for: fragment.rangeInElement)
        for entry in entries where NSIntersectionRange(entry.range, range).length > 0 {
            let local = range.location - entry.range.location
            var low = 0, high = entry.spans.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(entry.spans[middle].range) <= local { low = middle + 1 } else { high = middle }
            }
            for span in entry.spans[low...] {
                guard span.range.location < local + range.length else { break }
                let part = NSIntersectionRange(NSRange(location: entry.range.location + span.range.location, length: span.range.length), range)
                guard part.length > 0, let color = Self.color(span.codeClass), let textRange = textRange(part, in: content) else { continue }
                layout.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
            }
        }
    }

    private func request(_ entry: Entry) {
        guard let highlighter = Self.highlighter else { return }
        let (id, language, text) = (entry.id, entry.language, entry.text)
        Self.wanted.withLock { $0[id] = text }
        queue.async { [weak self] in
            guard Self.wanted.withLock({ $0[id] == text }), let spans = highlighter.highlight(block: id, language: language, text: text) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.install(spans, for: id, text: text) }
            }
        }
    }

    private func install(_ spans: [CodeSpan], for id: UInt64, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.text == text }) else { return }
        entries[index].spans = spans
        guard let layout = textView?.textLayoutManager, let content = layout.textContentManager,
            let range = textRange(entries[index].range, in: content)
        else { return }
        layout.invalidateRenderingAttributes(for: range)
    }

    private func forget(_ entry: Entry) {
        Self.wanted.withLock { _ = $0.removeValue(forKey: entry.id) }
        Self.highlighter?.forget(entry.id)
    }

    private func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        let document = content.documentRange.location
        guard let start = content.location(document, offsetBy: range.location),
            let end = content.location(document, offsetBy: NSMaxRange(range))
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// The info string's first word, as GitHub reads a fence's language: ` ```rust,ignore ` and ` ```{python} ` too.
    nonisolated static func language(_ fence: String) -> String {
        let info = fence.drop { $0 == " " || $0 == "`" || $0 == "~" }
        let word = info.prefix { !$0.isWhitespace && $0 != "," }
        return word.trimmingCharacters(in: CharacterSet(charactersIn: "{}.")).lowercased()
    }

    private static func color(_ codeClass: CodeClass) -> NSColor? {
        let token: Token? = switch codeClass {
        case .comment: .codeComment
        case .string: .codeString
        case .escape, .number, .constant: .codeNumber
        case .keyword: .codeKeyword
        case .type: .codeType
        case .function: .codeFunction
        case .tag, .attribute: .codeTag
        case .inserted: .codeInserted
        case .deleted: .codeDeleted
        case .heading: .heading
        case .operator: nil
        }
        return token.map(ThemeStore.shared.color)
    }
}
