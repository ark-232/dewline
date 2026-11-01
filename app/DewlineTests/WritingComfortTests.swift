import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    init(_ text: String, caret: Int? = nil) {
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: caret ?? text.utf16.count, length: 0))
    }

    var text: String { view.string }
    var caret: Int { view.selectedRange().location }

    func undo() {
        if view.styler.undoManager.groupingLevel > 0 { view.styler.undoManager.endUndoGrouping() }
        view.styler.undoManager.undo()
    }

    /// Whether the character at `index` is laid out hidden, as a fold leaves it.
    func isHidden(_ index: Int) -> Bool {
        let storage = view.textStorage!
        return (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) == MarkdownStyler.hiddenFont
            && storage.attribute(.dewlineBlock, at: index, effectiveRange: nil) != nil
    }
}

@MainActor
struct SmartListTests {
    @Test func returnContinuesTheList() {
        for (text, next) in [("- one", "- "), ("* one", "* "), ("1. one", "2. "), ("9) one", "10) "), ("- [x] done", "- [ ] "), ("  - one", "  - ")] {
            let editor = Editor(text)
            editor.view.insertNewline(nil)
            #expect(editor.text == text + "\n" + next)
            #expect(editor.caret == editor.text.utf16.count)
        }
    }

    @Test func returnSplitsAnItemAndKeepsItsLineEnding() {
        let editor = Editor("- one two\r\n- three", caret: 5)
        editor.view.insertNewline(nil)
        #expect(editor.text == "- one\r\n-  two\r\n- three")
        #expect(editor.caret == 9)
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        let editor = Editor("- one\n- ")
        editor.view.insertNewline(nil)
        #expect(editor.text == "- one\n")
        let task = Editor("1. [ ] one\n2. [ ] ")
        task.view.insertNewline(nil)
        #expect(task.text == "1. [ ] one\n")
    }

    @Test func returnOutsideAListIsPlain() {
        let editor = Editor("plain")
        editor.view.insertNewline(nil)
        #expect(editor.text == "plain\n")
        let marker = Editor("- one", caret: 0)
        marker.view.insertNewline(nil)
        #expect(marker.text == "\n- one")
    }

    @Test func continuationIsOneUndoableEdit() {
        let editor = Editor("- one")
        editor.view.insertNewline(nil)
        #expect(editor.text == "- one\n- ")
        editor.undo()
        #expect(editor.text == "- one")
    }

    @Test func tabIndentsAndShiftTabOutdents() {
        let editor = Editor("- one\n- two")
        editor.view.insertTab(nil)
        #expect(editor.text == "- one\n  - two")
        #expect(editor.caret == editor.text.utf16.count)
        editor.view.insertBacktab(nil)
        #expect(editor.text == "- one\n- two")
        #expect(editor.caret == editor.text.utf16.count)
        editor.view.insertTab(nil)
        editor.undo()
        #expect(editor.text == "- one\n- two")

        let ordered = Editor("1. one\n2. two")
        ordered.view.insertTab(nil)
        #expect(ordered.text == "1. one\n   2. two")
        let prose = Editor("prose")
        prose.view.insertTab(nil)
        #expect(prose.text == "prose\t")
    }
}

@MainActor
struct FoldTests {
    static let text = "# A\n\npara one\n\n## B\n\npara two\n\n# C\n\nthree\n\n```\ncode\n```\n"

    @Test func foldHidesAndUnfoldRestoresWithNoByteChange() throws {
        let editor = Editor(Self.text, caret: 0)
        let one = (Self.text as NSString).range(of: "para one").location
        let two = (Self.text as NSString).range(of: "para two").location
        let three = (Self.text as NSString).range(of: "three").location
        editor.view.foldBlock(nil)
        #expect(editor.text == Self.text)
        #expect(editor.view.styler.folds == [NSRange(location: 4, length: (Self.text as NSString).range(of: "# C").location - 5)])
        #expect(editor.isHidden(one) && editor.isHidden(two))
        #expect(!editor.isHidden(0) && !editor.isHidden(three))
        editor.view.unfoldBlock(nil)
        #expect(editor.text == Self.text)
        #expect(editor.view.styler.folds.isEmpty)
        #expect(!editor.isHidden(one) && !editor.isHidden(two))
    }

    @Test func foldAllAndUnfoldAll() {
        let editor = Editor(Self.text, caret: (Self.text as NSString).range(of: "para two").location)
        editor.view.foldAll(nil)
        #expect(editor.text == Self.text)
        // Three headings with text under them and the fence.
        #expect(editor.view.styler.folds.count == 4)
        #expect(editor.caret == 3)
        let code = (Self.text as NSString).range(of: "code").location
        #expect(editor.isHidden(code))
        editor.view.unfoldAll(nil)
        #expect(editor.view.styler.folds.isEmpty)
        #expect(!editor.isHidden(code))
        #expect(editor.text == Self.text)
    }

    @Test func caretMovingInUnfolds() {
        let editor = Editor(Self.text, caret: 0)
        editor.view.foldBlock(nil)
        let one = (Self.text as NSString).range(of: "para one").location
        editor.view.setSelectedRange(NSRange(location: one + 2, length: 0))
        #expect(editor.view.styler.folds.isEmpty)
        #expect(!editor.isHidden(one))
    }

    @Test func editsAboveMoveAFoldAndEditsInsideUnfoldIt() {
        let editor = Editor(Self.text, caret: 0)
        editor.view.foldBlock(nil)
        let fold = editor.view.styler.folds[0]
        editor.view.insertText("X", replacementRange: NSRange(location: 2, length: 0))
        #expect(editor.view.styler.folds == [NSRange(location: fold.location + 1, length: fold.length)])
        editor.view.textStorage!.replaceCharacters(in: NSRange(location: fold.location + 3, length: 1), with: "Q")
        #expect(editor.view.styler.folds.isEmpty)
    }
}

@MainActor
struct WordCountTests {
    static let sample = """
        ---
        title: Not counted here
        ---

        # Hello world

        Some **bold** text with a [link](https://example.com/path) and `code here`.

        - one item
        - [ ] task two

        ```swift
        let x = 1
        ```

        """

    @Test func countsProseOnly() {
        let map = BlockMap()
        let text = Self.sample as NSString
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: text.length)
        let blocks = map.blocks(in: NSRange(location: 0, length: text.length))
        let hello = text.range(of: "Hello world")
        let count = WordCount.count(Self.sample, blocks: blocks, selection: hello)
        #expect(count.total == 13)
        #expect(count.selected == 2)
    }

    @Test func labels() {
        #expect(WordCount.label(total: 1234, selected: nil) == "1,234 words")
        #expect(WordCount.label(total: 1234, selected: 12) == "12 of 1,234 words")
        #expect(WordCount.label(total: 1, selected: nil) == "1 word")
    }
}

@MainActor
struct SmartPunctuationTests {
    @Test func offByDefault() throws {
        let suite = "dev.arkwerx.dewline.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        #expect(!store.smartPunctuation)
        store.smartPunctuation = true
        #expect(ThemeStore(defaults: defaults).smartPunctuation)
    }

    @Test func skipsCode() {
        let text = "Say \"hi\" -- `x \"y\"`\n\n```\na -- \"b\"\n```\n"
        let editor = Editor(text, caret: 0)
        let string = text as NSString
        let prose = string.range(of: "\"hi\"")
        let dash = string.range(of: "--")
        let span = string.range(of: "\"y\"")
        let fenced = string.range(of: "\"b\"")
        let results = [
            NSTextCheckingResult.quoteCheckingResult(range: NSRange(location: prose.location, length: 1), replacementString: "“"),
            NSTextCheckingResult.dashCheckingResult(range: dash, replacementString: "—"),
            NSTextCheckingResult.quoteCheckingResult(range: NSRange(location: span.location, length: 1), replacementString: "“"),
            NSTextCheckingResult.quoteCheckingResult(range: NSRange(location: fenced.location, length: 1), replacementString: "“"),
            NSTextCheckingResult.dashCheckingResult(range: string.range(of: "--", options: .backwards), replacementString: "—"),
        ]
        let kept = editor.view.styler.textView(
            editor.view, didCheckTextIn: NSRange(location: 0, length: string.length), types: NSTextCheckingAllTypes, options: [:],
            results: results, orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 0
        )
        #expect(kept.map(\.range) == [results[0].range, results[1].range])
    }
}

@MainActor
struct ImagePasteTests {
    @Test func pasteWritesAFileBesideTheDocumentAndLinksIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let taken = folder.appending(path: "image-\(date)-1.png")
        try Data("keep".utf8).write(to: taken)

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let editor = Editor("Hi ")
        editor.view.documentFolder = folder
        #expect(editor.view.readSelection(from: pasteboard, type: .png))
        let name = "image-\(date)-2.png"
        #expect(editor.text == "Hi ![](\(name))")
        #expect(editor.caret == editor.text.utf16.count)
        #expect(try Data(contentsOf: folder.appending(path: name)) == png)
        #expect(try Data(contentsOf: taken) == Data("keep".utf8))
        editor.undo()
        #expect(editor.text == "Hi ")
    }

    @Test func textOnThePasteboardPastesAsText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("words", forType: .string)
        let editor = Editor("")
        editor.view.documentFolder = FileManager.default.temporaryDirectory
        #expect(!editor.view.insertImages(from: pasteboard))
    }
}

@MainActor
struct WritingModeTests {
    /// The ranges drawn in a rendering color, which leaves the storage alone.
    private func dimmed(_ view: EditorTextView) -> [NSRange] {
        let layout = view.textLayoutManager!
        let content = layout.textContentManager!
        var ranges: [NSRange] = []
        layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
            if attributes[.foregroundColor] != nil {
                let start = content.offset(from: content.documentRange.location, to: range.location)
                let found = NSRange(location: start, length: content.offset(from: range.location, to: range.endLocation))
                if let last = ranges.last, NSMaxRange(last) == start { ranges[ranges.count - 1] = NSUnionRange(last, found) } else { ranges.append(found) }
            }
            return true
        }
        return ranges
    }

    @Test func focusDimsAllButTheCaretsBlock() {
        let text = "One para.\n\nTwo para.\n\nThree.\n"
        let editor = Editor(text, caret: 13)
        let colors = editor.view.textStorage!.attributedSubstring(from: NSRange(location: 0, length: (text as NSString).length))
        editor.view.focusMode = true
        #expect(dimmed(editor.view) == [NSRange(location: 0, length: 11), NSRange(location: 21, length: 8)])
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(dimmed(editor.view) == [NSRange(location: 10, length: 19)])
        #expect(editor.view.textStorage!.isEqual(to: colors))
        editor.view.focusMode = false
        #expect(dimmed(editor.view).isEmpty)
    }

    @Test func typewriterLetsTheEndsReachTheMiddle() {
        let editor = Editor("text")
        let height = editor.view.enclosingScrollView!.contentView.bounds.height
        editor.view.typewriterMode = true
        #expect(editor.view.textContainerInset.height == (height / 2).rounded())
        editor.view.typewriterMode = false
        #expect(editor.view.textContainerInset.height == 24)
    }
}
