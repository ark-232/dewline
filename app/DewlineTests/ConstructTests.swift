import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView
    let text: String

    init(_ text: String, caret: Int, folder: URL? = nil) {
        self.text = text
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.documentFolder = folder
        view.string = text
        window.makeFirstResponder(view)
        place(caret)
    }

    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    func attribute(_ key: NSAttributedString.Key, at index: Int) -> Any? {
        view.textStorage!.attribute(key, at: index, effectiveRange: nil)
    }

    func hidden(_ index: Int) -> Bool {
        (attribute(.font, at: index) as! NSFont).pointSize < 1
    }

    func color(at index: Int) -> NSColor? {
        attribute(.foregroundColor, at: index) as? NSColor
    }

    func role(at index: Int) -> BlockLine.Role? {
        (attribute(.dewlineBlock, at: index) as? BlockLine)?.role
    }

    func isCollapsed(_ index: Int) -> Bool {
        guard case .collapsed? = role(at: index) else { return false }
        return true
    }

    func picture(at index: Int) -> BlockPicture? {
        guard case .picture(let picture, _)? = role(at: index) else { return nil }
        return picture
    }

    func summary(at index: Int) -> String? {
        guard case .summary(let line)? = role(at: index) else { return nil }
        return line.string
    }

    /// The spans of `kind`, in document offsets.
    func spans(_ kind: SyntaxSpan.Kind) -> [SyntaxSpan] {
        view.styler.map.blocks(in: NSRange(location: 0, length: (text as NSString).length))
            .flatMap { block in block.spans.map { $0.shifted(by: block.range.location) } }.filter { $0.kind == kind }
    }

    /// Visits every offset and checks that the text is the same, byte for byte.
    func expectBytesKept() {
        for caret in 0...(text as NSString).length { place(caret) }
        #expect(view.string == text)
        #expect(view.string.data(using: .utf8) == text.data(using: .utf8))
    }
}

@MainActor
struct ConstructTests {
    @Test func highlightWashesItsTextAndHidesItsMarkers() {
        let text = "A ==bright== day\n"
        let editor = Editor(text, caret: 16)
        #expect([2, 3, 10, 11].allSatisfy { editor.hidden($0) })
        #expect(editor.attribute(.backgroundColor, at: 5) != nil)
        #expect(!editor.hidden(5))
        editor.place(6)
        #expect(!editor.hidden(2) && !editor.hidden(10), "revealed under the caret")
        #expect(editor.attribute(.backgroundColor, at: 5) != nil)
        editor.expectBytesKept()
    }

    @Test func commentsAreDimWithTheirMarkersHidden() {
        let text = "Say %%aside%% here\n"
        let editor = Editor(text, caret: 0)
        #expect(editor.hidden(4) && editor.hidden(11))
        #expect(editor.color(at: 7) == ThemeStore.shared.color(.ink2))
        editor.place(8)
        #expect(!editor.hidden(4) && !editor.hidden(12))
        #expect(editor.color(at: 7) == ThemeStore.shared.color(.ink2))
        editor.expectBytesKept()
    }

    @Test func tagsAreDimTokensThatKeepTheirHash() {
        let text = "Plan #idea now\n"
        let editor = Editor(text, caret: 0)
        #expect(editor.spans(.tag).count == 1)
        for caret in [0, 7] {
            editor.place(caret)
            #expect(!editor.hidden(5), "the # shows")
            #expect(editor.color(at: 5) == ThemeStore.shared.color(.ink2))
            #expect(editor.color(at: 8) == ThemeStore.shared.color(.ink2))
            #expect(editor.attribute(.backgroundColor, at: 6) != nil)
        }
        #expect(editor.color(at: 1) == ThemeStore.shared.color(.ink))
        editor.expectBytesKept()
    }

    @Test func footnoteReferencesAreSuperscriptAndFindTheirDefinition() {
        let text = "Text[^1] more.\n\n[^1]: The note,\n    on two lines.\n"
        let editor = Editor(text, caret: 0)
        #expect(editor.hidden(4) && editor.hidden(5) && editor.hidden(7))
        let offset = editor.attribute(.baselineOffset, at: 6) as? NSNumber
        #expect((offset?.doubleValue ?? 0) > 0)
        #expect((editor.attribute(.font, at: 6) as! NSFont).pointSize < MarkdownStyler.bodyFont.pointSize)
        editor.place(6)
        #expect(!editor.hidden(4) && !editor.hidden(7))
        let definition = editor.view.footnoteDefinition("1")
        #expect(definition?.text == "The note, on two lines.")
        #expect(definition?.range.location == 16)
        #expect(editor.view.footnoteDefinition("2") == nil)
        editor.expectBytesKept()
    }

    @Test func calloutsHideTheirTypeAndBoldTheirTitle() {
        let text = "> [!warning] Careful now\n> body\n\nEnd"
        let editor = Editor(text, caret: (text as NSString).length)
        #expect([0, 2, 5, 11].allSatisfy { editor.hidden($0) })
        #expect(editor.attribute(.dewlineCallout, at: 14) as? String == "warning")
        #expect(editor.attribute(.dewlineCallout, at: 27) as? String == "warning")
        #expect(editor.attribute(.dewlineCallout, at: 33) == nil)
        let title = editor.attribute(.font, at: 14) as! NSFont
        #expect(title.fontDescriptor.symbolicTraits.contains(.bold))
        let body = editor.attribute(.font, at: 27) as! NSFont
        #expect(!body.fontDescriptor.symbolicTraits.contains(.bold))
        let titleIndent = (editor.attribute(.paragraphStyle, at: 14) as! NSParagraphStyle).firstLineHeadIndent
        let bodyIndent = (editor.attribute(.paragraphStyle, at: 27) as! NSParagraphStyle).firstLineHeadIndent
        #expect(titleIndent == bodyIndent + Constructs.iconSpace)
        editor.place(5)
        #expect(!editor.hidden(2) && !editor.hidden(5) && !editor.hidden(11), "the type shows under the caret")
        editor.expectBytesKept()
    }

    @Test func calloutTypesHaveIconsAndAliasesShareThem() {
        for type in ["note", "tip", "warning", "danger", "info", "quote", "abstract", "todo", "success", "question", "failure", "bug", "example"] {
            #expect(NSImage(systemSymbolName: Constructs.look(type).symbol, accessibilityDescription: nil) != nil, "\(type)")
        }
        #expect(Constructs.look("caution").symbol == Constructs.look("warning").symbol)
        #expect(Constructs.look("cite").symbol == Constructs.look("quote").symbol)
        #expect(Constructs.look("error").symbol == Constructs.look("danger").symbol)
        #expect(Constructs.look("hint").symbol == Constructs.look("tip").symbol)
        #expect(Constructs.look("unknown").symbol == Constructs.look("note").symbol)
    }

    @Test func wikilinksShowTheAliasOrTheName() {
        let text = "See [[Note|the alias]] and [[Other#Part]] now\n"
        let editor = Editor(text, caret: 0)
        #expect((4..<11).allSatisfy { editor.hidden($0) })
        #expect(editor.hidden(20) && editor.hidden(21))
        #expect(editor.color(at: 12) == ThemeStore.shared.color(.link))
        #expect(editor.attribute(.underlineStyle, at: 12) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(editor.hidden(27) && !editor.hidden(29))
        #expect(editor.color(at: 29) == ThemeStore.shared.color(.link))
        let targets = editor.spans(.wikiLink).map { editor.view.wikilinkTarget(of: $0) }
        #expect(targets == ["Note", "Other#Part"])
        editor.place(12)
        #expect(!editor.hidden(4) && !editor.hidden(20))
        editor.expectBytesKept()
    }

    @Test func noteEmbedsAreLinksAndImageEmbedsArePictures() async throws {
        let folder = try RenderedBlockTests.imageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "Above ![[Some note]] here\n\n![[\(RenderedBlockTests.picturePath)]]\n\nBelow\n"
        let editor = Editor(text, caret: 0, folder: folder)
        #expect(editor.hidden(6) && editor.hidden(8))
        #expect(editor.color(at: 10) == ThemeStore.shared.color(.link))
        #expect(editor.view.wikilinkTarget(of: editor.spans(.embed)[0]) == "Some note")
        let start = 27
        let deadline = ContinuousClock.now + .seconds(5)
        while editor.picture(at: start) == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let picture = try #require(editor.picture(at: start))
        #expect(picture.size.width > 0)
        editor.place(start + 4)
        #expect(editor.attribute(.dewlineBlock, at: start) == nil, "the source shows under the caret")
        editor.expectBytesKept()
    }

    @Test func frontMatterFoldsToOneLineAndUnfoldsUnderTheCaret() {
        let text = "---\ntitle: A\ntags:\n  - b\n# note\n---\n\nBody\n"
        let body = (text as NSString).range(of: "Body").location
        let editor = Editor(text, caret: body)
        #expect(editor.summary(at: 0) == "Front matter · 2 fields")
        #expect(editor.isCollapsed(5))
        #expect(editor.hidden(5))
        editor.place(6)
        #expect(editor.attribute(.dewlineBlock, at: 0) == nil && editor.attribute(.dewlineBlock, at: 5) == nil, "unfolded")
        #expect(!editor.hidden(5))
        editor.place(body)
        #expect(editor.summary(at: 0) == "Front matter · 2 fields", "folded again")
        editor.expectBytesKept()
    }

    @Test func linkDestinationsComeFromTheLinkOrItsDefinition() {
        let text = "[a](other.md#Sec) and [b][ref] and <https://example.com/x>\n\n[ref]: <https://example.com> \"T\"\n"
        let editor = Editor(text, caret: 0)
        let destinations: [String?] = editor.spans(.link).map { editor.view.destination(of: $0) }
        #expect(destinations == ["other.md#Sec", "https://example.com", "https://example.com/x"])
    }

    @Test func headingJumpsIgnoreCase() {
        let text = "# Top\n\nText\n\n## Second part\n"
        let editor = Editor(text, caret: 0)
        #expect(editor.view.jump(toHeading: "second PART"))
        #expect(editor.view.selectedRange().location == 13)
        #expect(!editor.view.jump(toHeading: "Nowhere"))
    }
}

struct LinkTargetTests {
    /// A folder holding `Note.md`, `sub/Note.md` and `sub/Deep Dive.md`.
    static func notes() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-notes-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        for path in ["Note.md", "sub/Note.md", "sub/Deep Dive.md"] {
            try Data("# Part\n".utf8).write(to: folder.appending(path: path))
        }
        return folder
    }

    @Test func wikilinksResolveByNameIgnoringCaseAndExtension() throws {
        let folder = try Self.notes()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Note.md")
        #expect(Links.target(ofWikilink: "note", in: folder) == .note(note, heading: nil))
        #expect(Links.target(ofWikilink: "NOTE.md", in: folder) == .note(note, heading: nil))
        #expect(Links.target(ofWikilink: "Note#Part", in: folder) == .note(note, heading: "Part"))
        #expect(Links.target(ofWikilink: "deep dive", in: folder) == .note(folder.appending(path: "sub/Deep Dive.md"), heading: nil))
        #expect(Links.target(ofWikilink: "sub/note", in: folder) == .note(folder.appending(path: "sub/Note.md"), heading: nil))
        #expect(Links.target(ofWikilink: "#Part", in: folder) == .heading("Part"))
    }

    @Test func aMissingWikilinkTargetsANewNoteInTheFolder() throws {
        let folder = try Self.notes()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Links.target(ofWikilink: "Fresh Idea", in: folder) == .missing(folder.appending(path: "Fresh Idea.md")))
        #expect(Links.target(ofWikilink: "fresh.md", in: folder) == .missing(folder.appending(path: "fresh.md")))
        #expect(Links.target(ofWikilink: "../escape", in: folder) == .refused)
        #expect(Links.target(ofWikilink: "/etc/hosts", in: folder) == .refused)
        #expect(Links.target(ofWikilink: "note", in: nil) == .refused)
    }

    @Test func linksOpenOnlyWebAddressesAndNotes() throws {
        let folder = try Self.notes()
        defer { try? FileManager.default.removeItem(at: folder) }
        for refused in [
            "javascript:alert(1)", "JavaScript:alert(1)", " java\tscript:alert(1)", "java\nscript:alert(1)", "data:text/html,<b>x</b>",
            "file:///etc/passwd", "FILE:///etc/hosts", "vbscript:x", "/etc/notes.md", "~/notes.md", "picture.png", "ftp://example.com",
        ] {
            #expect(Links.target(of: refused, from: folder) == .refused, "\(refused.debugDescription)")
        }
        #expect(Links.target(of: "https://example.com/a", from: folder) == .web(URL(string: "https://example.com/a")!))
        #expect(Links.target(of: "HTTP://example.com", from: nil) == .web(URL(string: "HTTP://example.com")!))
        #expect(Links.target(of: "mailto:a@example.com", from: nil) == .web(URL(string: "mailto:a@example.com")!))
        #expect(Links.target(of: "Note.md#Part", from: folder) == .note(folder.appending(path: "Note.md"), heading: "Part"))
        #expect(Links.target(of: "sub/Deep%20Dive.md", from: folder) == .note(folder.appending(path: "sub/Deep Dive.md"), heading: nil))
        #expect(Links.target(of: "Later.md", from: folder) == .missing(folder.appending(path: "Later.md")))
        #expect(Links.target(of: "#Part", from: nil) == .heading("Part"))
    }
}
