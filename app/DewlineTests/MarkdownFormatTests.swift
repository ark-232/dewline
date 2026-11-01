import AppKit
import Testing
@testable import Dewline

/// Text with its selection marked: `|` for a caret, `«` and `»` around a selection.
private func marked(_ text: String) -> (NSString, NSRange) {
    let string = NSMutableString(string: text)
    let caret = string.range(of: "|")
    if caret.location != NSNotFound {
        string.deleteCharacters(in: caret)
        return (string, NSRange(location: caret.location, length: 0))
    }
    let start = string.range(of: "«").location
    string.deleteCharacters(in: NSRange(location: start, length: 1))
    let end = string.range(of: "»").location
    string.deleteCharacters(in: NSRange(location: end, length: 1))
    return (string, NSRange(location: start, length: end - start))
}

private func marking(_ text: NSString, _ selection: NSRange) -> String {
    let string = NSMutableString(string: text)
    if selection.length == 0 {
        string.insert("|", at: selection.location)
    } else {
        string.insert("»", at: NSMaxRange(selection))
        string.insert("«", at: selection.location)
    }
    return string as String
}

/// The marked text after `command`, or nil when it makes no edit.
private func run(_ command: MarkdownFormat, _ before: String) -> String? {
    let (text, selection) = marked(before)
    guard let edit = command.edit(in: text, selection: selection) else { return nil }
    let after = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
    return marking(after, edit.selection)
}

struct MarkdownFormatTests {
    @Test(arguments: [
        (MarkdownFormat.bold, "a «word» b", "a **«word»** b"),
        (.bold, "a **«word»** b", "a «word» b"),
        (.bold, "a «**word**» b", "a «word» b"),
        (.bold, "a *«*word*»* b", "a «word» b"),
        (.bold, "a | b", "a **|** b"),
        (.bold, "a **|** b", "a | b"),
        (.bold, "a wo|rd b", "a **wo|rd** b"),
        (.bold, "a **wo|rd** b", "a wo|rd b"),
        (.bold, "a «word » b", "a **«word»**  b"),
        (.bold, "«word»", "**«word»**"),
        (.bold, "|", "**|**"),
        (.bold, "word|", "**word|**"),
        (.bold, "|word", "**|word**"),
        (.bold, "«one\r\ntwo»", "**«one\r\ntwo»**"),
        (.bold, "*«both»*", "***«both»***"),
        (.bold, "***«both»***", "*«both»*"),
        (.italic, "a «word» b", "a *«word»* b"),
        (.italic, "a *«word»* b", "a «word» b"),
        (.italic, "**«bold»**", "***«bold»***"),
        (.italic, "***«both»***", "**«both»**"),
        (.italic, "*|*", "|"),
        (.strikethrough, "«gone»", "~~«gone»~~"),
        (.strikethrough, "~~go|ne~~", "go|ne"),
        (.highlight, "a «mark» b", "a ==«mark»== b"),
        (.highlight, "«==mark==»", "«mark»"),
        (.code, "run «ls»", "run `«ls»`"),
        (.code, "run `l|s`", "run l|s"),
        (.code, "run |", "run `|`"),
        (.link, "a «word» b", "a [word](|) b"),
        (.link, "a wo|rd b", "a [word](|) b"),
        (.link, "a | b", "a [|]() b"),
        (.link, "see [«text»](https://example.com) now", "see «text» now"),
        (.link, "see [te|xt](https://example.com) now", "see «text» now"),
    ])
    func wrapsAndUnwraps(command: MarkdownFormat, before: String, after: String) {
        #expect(run(command, before) == after)
    }

    @Test(arguments: [
        (MarkdownFormat.heading1, "|Title", "# |Title"),
        (.heading1, "# Ti|tle", "Ti|tle"),
        (.heading2, "# Ti|tle", "## Ti|tle"),
        (.heading3, "- it|em", "### it|em"),
        (.heading1, "> quo|te", "> # quo|te"),
        (.heading1, "«one\n\ntwo»", "# «one\n\n# two»"),
        (.heading6, "a\r\nb|", "a\r\n###### b|"),
        (.body, "## Ti|tle", "Ti|tle"),
        (.body, "> - [x] it|em", "it|em"),
        (.quote, "«one\r\ntwo»\r\n", "> «one\r\n> two»\r\n"),
        (.quote, "> «one\r\n> two»\r\n", "«one\r\ntwo»\r\n"),
        (.quote, "> «one\ntwo»", "> «one\n> two»"),
        (.quote, "    co|de", ">     co|de"),
        (.bulletedList, "|", "- |"),
        (.bulletedList, "«one\r\ntwo\r\n»three", "- «one\r\n- two\r\n»three"),
        (.bulletedList, "- «one\n* two»", "«one\ntwo»"),
        (.bulletedList, "1. it|em", "- it|em"),
        (.bulletedList, "- [ ] it|em", "- it|em"),
        (.bulletedList, "> it|em", "> - it|em"),
        (.bulletedList, "  it|em", "  - it|em"),
        (.numberedList, "«a\nb\n\nc»", "1. «a\n2. b\n\n3. c»"),
        (.numberedList, "1. «a\n2) b»", "«a\nb»"),
        (.task, "- it|em", "- [ ] it|em"),
        (.task, "- [x] it|em", "it|em"),
        (.task, "«a\nb»", "- [ ] «a\n- [ ] b»"),
    ])
    func formatsLines(command: MarkdownFormat, before: String, after: String) {
        #expect(run(command, before) == after)
    }

    @Test func bodyTextOnAPlainLineMakesNoEdit() {
        #expect(run(.body, "pla|in") == nil)
        #expect(run(.heading1, "«a\n\n»") != nil)
    }

    @Test(arguments: [
        (MarkdownFormat.moveLineUp, "a\nb|\nc", "b|\na\nc"),
        (.moveLineDown, "a\nb|\nc", "a\nc\nb|"),
        (.moveLineUp, "a\nb|", "b|\na"),
        (.moveLineDown, "a|\nb", "b\na|"),
        (.moveLineUp, "a\r\nb|\r\n", "b|\r\na\r\n"),
        (.moveLineDown, "a\r\nb|\nc", "a\r\nc\nb|"),
        (.moveLineDown, "«a\nb»\nc", "c\n«a\nb»"),
        (.moveLineDown, "«a\n»b\nc", "b\n«a\n»c"),
        (.moveLineDown, "«a\n»b", "b\n«a»"),
        (.moveLineUp, "x\r\n«y»", "«y»\r\nx"),
        (.moveLineUp, "«a\nb»\nc", nil),
        (.moveLineDown, "a\nb|", nil),
        (.moveLineDown, "a|\n", nil),
        (.moveLineUp, "a\n|", nil),
        (.moveLineUp, "|", nil),
    ] as [(MarkdownFormat, String, String?)])
    func movesLines(command: MarkdownFormat, before: String, after: String?) {
        #expect(run(command, before) == after)
    }

    /// Each command through the editor: one edit, named for the command, that undo takes back to the exact bytes.
    @MainActor @Test func everyCommandIsOneNamedUndoableEdit() {
        let text = "a\r\n## Some bold text\r\nlast"
        // A window that is never ordered front.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = EditorTextView.scrollView()
        window.contentView = scrollView
        let view = scrollView.documentView as! EditorTextView
        window.makeFirstResponder(view)
        let undo = view.styler.undoManager
        for command in MarkdownFormat.allCases {
            view.string = text
            undo.removeAllActions()
            view.setSelectedRange((text as NSString).range(of: "bold"))
            let item = NSMenuItem(title: command.name, action: #selector(EditorTextView.format(_:)), keyEquivalent: "")
            item.tag = command.rawValue
            #expect(view.validateMenuItem(item))
            view.format(item)
            undo.endUndoGrouping()
            #expect(view.string != text, "\(command.name)")
            #expect(undo.undoMenuItemTitle == "Undo \(command.name)")
            undo.undo()
            #expect(view.string == text, "\(command.name)")
            #expect(!undo.canUndo)
        }
    }

    @MainActor @Test func nothingRunsWhileAnInputMethodComposes() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = EditorTextView.scrollView()
        window.contentView = scrollView
        let view = scrollView.documentView as! EditorTextView
        window.makeFirstResponder(view)
        view.string = "word "
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        let item = NSMenuItem(title: "Bold", action: #selector(EditorTextView.format(_:)), keyEquivalent: "")
        item.tag = MarkdownFormat.bold.rawValue
        view.format(item)
        #expect(view.string == "word か")
        view.unmarkText()
    }
}
