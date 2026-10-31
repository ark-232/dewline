import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    init(_ text: String, caret: Int) {
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        place(caret)
    }

    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// The first occurrence of `string` at or after `from`.
    func find(_ string: String, from: Int = 0) -> NSRange {
        let text = view.string as NSString
        return text.range(of: string, range: NSRange(location: from, length: text.length - from))
    }

    func rect(_ range: NSRange) -> NSRect {
        view.firstRect(forCharacterRange: range, actualRange: nil)
    }

    func rect(_ string: String, from: Int = 0) -> NSRect {
        rect(find(string, from: from))
    }

    func role(at location: Int) -> BlockLine.Role? {
        (view.textStorage!.attribute(.dewlineBlock, at: location, effectiveRange: nil) as? BlockLine)?.role
    }

    /// Runs `edit` in its own undo group, as an event would.
    func edit(_ edit: () -> Void) {
        let undo = view.styler.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        edit()
        undo.endUndoGrouping()
    }
}

@MainActor
struct TableTests {
    static let text = "Intro\n\n| Name | Qty | Note |\n|:-----|----:|:----:|\n| apple | 3 | ok |\n| kiwi fruit | 12 | fine one |\n\nAfter\n"

    @Test func columnsAlignFromTheWidestCell() throws {
        let editor = Editor(Self.text, caret: 0)
        #expect(editor.view.string == Self.text)
        let gap = (MarkdownStyler.bodyFont.pointSize * 1.5).rounded()
        // Pipes and padding take no space.
        let head = editor.find("| Name")
        #expect(editor.rect(NSRange(location: head.location, length: 2)).width <= 0.5)
        // A caret position splits the kern before it, so a cell's start is its end less its laid-out width.
        func cell(_ string: String, skip: Int = 0) -> (start: CGFloat, end: CGFloat) {
            var range = editor.find(string)
            range = NSRange(location: range.location + skip, length: range.length - 2 * skip)
            let end = editor.rect(range).maxX
            return (end - editor.view.textStorage!.attributedSubstring(from: range).size().width, end)
        }
        // Left: every cell starts at the column's start.
        let name = cell("Name"), apple = cell("apple"), kiwi = cell("kiwi fruit")
        #expect(abs(apple.start - name.start) <= 0.5 && abs(kiwi.start - name.start) <= 0.5)
        // Right: every cell ends at the column's end, which the widest cell sets.
        let qty = cell("Qty"), three = cell(" 3 ", skip: 1), twelve = cell("12")
        #expect(abs(three.end - qty.end) <= 0.5 && abs(twelve.end - qty.end) <= 0.5)
        let first = (kiwi.end - kiwi.start).rounded(.up)
        let second = max(qty.end - qty.start, twelve.end - twelve.start).rounded(.up)
        #expect(abs(qty.end - (name.start + first + gap + second)) <= 1)
        // Center: every cell's middle is the column's, the widest cell's.
        let note = cell("Note"), ok = cell("ok"), fine = cell("fine one")
        let middle = (fine.start + fine.end) / 2
        #expect(abs((note.start + note.end) / 2 - middle) <= 1 && abs((ok.start + ok.end) / 2 - middle) <= 1)
        #expect(abs(fine.start - (qty.end + gap)) <= 1)
        // Rules: between columns on each line, and across under the head.
        guard case .table(let rule)? = editor.role(at: editor.find("| apple").location) else { Issue.record("no rule on a row"); return }
        #expect(rule.columns.count == 2 && !rule.across)
        guard case .table(let under)? = editor.role(at: editor.find("|:---").location) else { Issue.record("no rule under the head"); return }
        #expect(under.across && under.columns == rule.columns)
        #expect(Tables.alignments("|:-----|----:|:----:|") == [.left, .right, .center])
        #expect(editor.view.string == Self.text)
    }

    @Test func theCaretsRowShowsItsSource() {
        let editor = Editor(Self.text, caret: 0)
        let row = editor.find("| apple")
        let other = editor.find("| kiwi")
        #expect(editor.rect(NSRange(location: row.location, length: 1)).width <= 0.5)
        editor.place(editor.find("apple").location + 2)
        #expect(editor.rect(NSRange(location: row.location, length: 1)).width > 2)
        #expect(editor.role(at: row.location) == nil)
        #expect(editor.rect(NSRange(location: other.location, length: 1)).width <= 0.5)
        // The head shows its delimiter row with it.
        let delimiter = editor.find("|:---")
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width <= 0.5)
        editor.place(editor.find("Name").location)
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width > 2)
        #expect(editor.rect(NSRange(location: row.location, length: 1)).width <= 0.5)
        editor.place(0)
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width <= 0.5)
        #expect(editor.view.string == Self.text)
    }

    @Test func columnsOnlyWidenWhileTyping() {
        let editor = Editor(Self.text, caret: 0)
        let view = editor.view
        func qtyEnd() -> CGFloat { editor.rect("Qty").maxX }
        let start = qtyEnd()
        // Shortening the widest cell keeps the column while the caret stays in the table.
        editor.place(NSMaxRange(editor.find("kiwi fruit")))
        for _ in 0..<6 { editor.edit { view.deleteBackward(nil) } }
        #expect(view.string.contains("| kiwi | 12 |"))
        #expect(abs(qtyEnd() - start) <= 0.5)
        // Leaving the table fits the columns again.
        editor.place(0)
        #expect(qtyEnd() < start - 10)
        // Typing a longer cell widens them at once.
        let narrow = qtyEnd()
        editor.place(NSMaxRange(editor.find("kiwi")))
        editor.edit { view.insertText(" and a much longer name", replacementRange: view.selectedRange()) }
        #expect(qtyEnd() > start + 10)
        #expect(qtyEnd() > narrow)
    }
}

@MainActor
struct TaskBoxTests {
    static let text = "- [ ] Buy milk\n- [x] Done\n\nEnd\n"

    @Test func aClickTogglesOneByteAndUndoRestoresIt() throws {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        let view = editor.view
        guard case .task(let task)? = editor.role(at: 0) else { Issue.record("no box"); return }
        #expect(!task.checked && task.label == "Buy milk" && task.at == 2)
        // The box sits over its `[ ]`.
        let chars = view.convert(editor.window.convertFromScreen(editor.rect(NSRange(location: 2, length: 3))), from: nil)
        #expect(view.taskBox(at: NSPoint(x: chars.midX, y: chars.midY)) == 3)
        #expect(view.taskBox(at: NSPoint(x: chars.maxX + 40, y: chars.midY)) == nil)
        let caret = view.selectedRange()
        let point = view.convert(NSPoint(x: chars.midX, y: chars.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        editor.edit { view.mouseDown(with: click) }
        let before = Array(Self.text.utf8), after = Array(view.string.utf8)
        #expect(after.count == before.count)
        #expect(zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset) == [3])
        #expect(view.string.hasPrefix("- [x] Buy milk"))
        #expect(view.selectedRange() == caret)
        guard case .task(let checked)? = editor.role(at: 0) else { Issue.record("no box after the click"); return }
        #expect(checked.checked)
        view.styler.undoManager.undo()
        #expect(view.string == Self.text)
    }

    @Test func boxesAreCheckboxesToAccessibility() {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        let boxes = (editor.view.accessibilityChildren() ?? []).compactMap { $0 as? TaskBoxElement }
        #expect(boxes.map { $0.accessibilityRole() } == [.checkBox, .checkBox])
        #expect(boxes.map { $0.accessibilityLabel() } == ["Buy milk", "Done"])
        #expect(boxes.map { $0.accessibilityValue() as? Int } == [0, 1])
        editor.edit { _ = boxes.first?.accessibilityPerformPress() }
        #expect(editor.view.string == Self.text.replacingOccurrences(of: "- [ ] Buy", with: "- [x] Buy"))
    }

    @Test func theCaretShowsTheBoxsSource() {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        #expect(editor.role(at: 0) != nil)
        editor.place(3)
        #expect(editor.role(at: 0) == nil)
        #expect(editor.view.textStorage!.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor != NSColor.clear)
        editor.place(Self.text.utf16.count)
        #expect(editor.role(at: 0) != nil)
        #expect(editor.view.string == Self.text)
    }
}
