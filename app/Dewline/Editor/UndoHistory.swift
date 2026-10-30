import AppKit
import MdCore

/// The editor's undo history for its text. Each entry is the edits that undo one of your actions; a landing moves
/// the entries past its edits instead of clearing them, so undo never touches landed text. The undo manager carries
/// one action per entry, which gives the menu, the action names and the document's change count.
@MainActor
final class UndoHistory {
    /// One undoable action, as the edits that undo it, in the buffer's coordinates while it is next.
    final class Entry {
        var edits: [ChangeEngine.Edit] = []
        var name = ""
    }

    let undoManager: UndoManager
    weak var textView: EditorTextView?
    /// Oldest first, as the undo manager holds their actions.
    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []
    /// While true, storage edits are the history's own or a landing's.
    private var suspended = false
    /// What the next storage edit replaces, read before it.
    private var pending: (ranges: [NSRange], texts: [String], old: [String])?
    /// The top entry takes the next typing edit that touches it.
    private var open = false
    private var lastTyped: (time: ContinuousClock.Instant, endsInSpace: Bool)?
    /// Set while a named action runs: its edits make one entry with this name.
    private var action: String?
    private var actionEntry: Entry?
    /// Typing and compositions coalesce; anything else is its own entry.
    var typing = false
    var composing = false

    /// Typing after this long starts a new entry.
    private static let pause: Duration = .seconds(2)

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    func breakCoalescing() {
        open = false
        lastTyped = nil
    }

    /// Runs `body`, whose edits make one entry named `name`.
    func perform(_ name: String, _ body: () -> Void) {
        let outer = action == nil
        if outer {
            breakCoalescing()
            action = name
        }
        body()
        if outer {
            action = nil
            actionEntry = nil
            breakCoalescing()
        }
    }

    /// Called when the text view approves an edit, before it happens.
    func willEdit(_ ranges: [NSRange], with texts: [String]) {
        guard !suspended, let storage = textView?.textStorage else { return }
        pending = (ranges, texts, ranges.map { storage.mutableString.substring(with: $0) })
    }

    /// An approved edit that never reached the storage records nothing.
    func didChangeText() {
        pending = nil
    }

    /// Called after each storage edit, with its range after the edit and its change in length.
    func didEdit(_ range: NSRange, delta: Int) {
        guard !suspended else { return }
        guard let pending else {
            // An edit no one approved: move the history past it, as past a landing.
            let text = (textView?.textStorage?.mutableString.substring(with: range)) ?? ""
            landed([ChangeEngine.Edit(range: NSRange(location: range.location, length: range.length - delta), text: text)])
            return
        }
        self.pending = nil
        record(pending.ranges, pending.texts, pending.old)
    }

    private func record(_ ranges: [NSRange], _ texts: [String], _ old: [String]) {
        let now = ContinuousClock.now
        let entry: Entry
        if let actionEntry {
            entry = actionEntry
        } else if let top = undoStack.last, coalesces(ranges, texts, into: top, at: now) {
            entry = top
        } else {
            entry = Entry()
        }
        // Simultaneous edits, last first, so each one's range still holds when it merges.
        for index in ranges.indices.reversed() {
            merge(ranges[index], length: texts[index].utf16.count, old: old[index], into: entry)
        }
        if typing || composing {
            open = true
            let last = texts.last ?? ""
            lastTyped = (now, last.last.map { $0.isWhitespace } ?? lastTyped?.endsInSpace ?? false)
        } else if action == nil {
            breakCoalescing()
        }
        if action != nil { actionEntry = entry }
        guard entry !== undoStack.last, !entry.edits.isEmpty else { return }
        undoStack.append(entry)
        redoStack = []
        entry.name = action ?? (typing || composing ? "Typing" : "")
        register(entry)
    }

    private func coalesces(_ ranges: [NSRange], _ texts: [String], into top: Entry, at now: ContinuousClock.Instant) -> Bool {
        guard composing || typing, open, ranges.count == 1 else { return false }
        if composing { return true }
        guard let lastTyped, now - lastTyped.time < Self.pause else { return false }
        // A word after a space starts a new entry.
        if lastTyped.endsInSpace, let first = texts[0].first, !first.isWhitespace { return false }
        let range = ranges[0]
        return top.edits.contains { $0.range.location <= NSMaxRange(range) && range.location <= NSMaxRange($0.range) }
    }

    /// Folds the edit replacing `range` (whose text is `old`) with `length` new units into `entry`: edits it touches
    /// merge with it into one, which puts back their original text and the old text between them.
    private func merge(_ range: NSRange, length: Int, old: String, into entry: Entry) {
        let delta = length - range.length
        let old = old as NSString
        var before: [ChangeEngine.Edit] = []
        var after: [ChangeEngine.Edit] = []
        var touched: [ChangeEngine.Edit] = []
        for edit in entry.edits {
            if NSMaxRange(edit.range) < range.location {
                before.append(edit)
            } else if edit.range.location > NSMaxRange(range) {
                after.append(ChangeEngine.Edit(range: NSRange(location: edit.range.location + delta, length: edit.range.length), text: edit.text))
            } else {
                touched.append(edit)
            }
        }
        if touched.isEmpty, range.length == 0, length == 0 { return }
        let start = min(range.location, touched.first?.range.location ?? range.location)
        let end = max(NSMaxRange(range), touched.last.map { NSMaxRange($0.range) } ?? 0)
        // The original text: each touched edit's, and between them the text this edit replaces.
        var text = ""
        var cursor = start
        for edit in touched {
            if cursor < edit.range.location {
                text += old.substring(with: NSRange(location: cursor - range.location, length: edit.range.location - cursor))
            }
            text += edit.text
            cursor = NSMaxRange(edit.range)
        }
        if cursor < end {
            text += old.substring(with: NSRange(location: cursor - range.location, length: end - cursor))
        }
        entry.edits = before + [ChangeEngine.Edit(range: NSRange(location: start, length: end - start + delta), text: text)] + after
    }

    private func register(_ entry: Entry) {
        undoManager.registerUndo(withTarget: entry) { [weak self] entry in
            MainActor.assumeIsolated { self?.run(entry) }
        }
        undoManager.setActionName(entry.name)
    }

    /// Undoes or redoes `entry`, which registers the entry that takes it back.
    private func run(_ entry: Entry) {
        undoStack.removeAll { $0 === entry }
        redoStack.removeAll { $0 === entry }
        breakCoalescing()
        guard let textView, let storage = textView.textStorage else { return }
        let inverse = Entry()
        inverse.name = entry.name
        var shift = 0
        for edit in entry.edits {
            let length = edit.text.utf16.count
            inverse.edits.append(ChangeEngine.Edit(
                range: NSRange(location: edit.range.location + shift, length: length),
                text: storage.mutableString.substring(with: edit.range)))
            shift += length - edit.range.length
        }
        suspended = true
        if textView.shouldChangeText(inRanges: entry.edits.map { NSValue(range: $0.range) }, replacementStrings: entry.edits.map(\.text)) {
            storage.beginEditing()
            for edit in entry.edits.reversed() {
                storage.replaceCharacters(in: edit.range, with: edit.text)
            }
            storage.endEditing()
            textView.didChangeText()
        }
        suspended = false
        if let first = inverse.edits.first {
            textView.setSelectedRange(NSRange(location: first.range.location, length: entry.edits[0].text.utf16.count))
        }
        if undoManager.isUndoing { redoStack.append(inverse) } else { undoStack.append(inverse) }
        register(inverse)
    }

    /// Applies a landing's storage edits in `body`, then moves the history past `edits`, the same change as hunks.
    func land(_ edits: [ChangeEngine.Edit], _ body: () -> Void) {
        suspended = true
        body()
        suspended = false
        landed(edits)
    }

    /// Moves every entry past `edits`; entries from the first one they touch back are dropped, and redo empties.
    private func landed(_ edits: [ChangeEngine.Edit]) {
        breakCoalescing()
        let mapped = undoStack.isEmpty ? [] : ChangeEngine.mapUndo(undoStack.map(\.edits), through: edits)
        let kept = undoStack.suffix(mapped.count)
        for (entry, edits) in zip(kept, mapped) {
            entry.edits = edits
        }
        for entry in undoStack.prefix(undoStack.count - mapped.count) + redoStack {
            undoManager.removeAllActions(withTarget: entry)
        }
        undoStack = Array(kept)
        redoStack = []
    }
}
