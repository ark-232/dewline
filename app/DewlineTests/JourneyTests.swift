import AppKit
import MdCore
import Testing
@testable import Dewline

/// The core journeys, each a whole path through the app: first launch, writing a note, finding and following notes,
/// reviewing what an agent changed, saving and opening again, git, snapshots and export. Each runs in the test host
/// on a temporary folder with an engine store of its own, in windows that are never ordered on screen.
@MainActor
@Suite(.serialized)
struct JourneyTests {
    private static let type = "net.daringfireball.markdown"

    // MARK: J1 First launch and a new note

    /// With no session, nothing reopens, so AppKit asks for the launch window; its first action is New.
    @Test func j1FirstLaunchHasNoSessionAndTheLaunchWindowStartsANewNote() throws {
        let suite = "dev.arkwerx.dewline.tests.journey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Session.load(from: defaults) == nil)

        let launch = LaunchWindowController()
        let window = try #require(launch.window)
        defer { window.close() }
        #expect(!window.isVisible)
        let buttons = Self.views(in: window.contentView!).compactMap { $0 as? NSButton }
        let new = try #require(buttons.first { $0.title == "New Note" })
        #expect(new.action == #selector(AppDelegate.newDocument(_:)) && new.keyEquivalent == "\r")
        #expect((NSApp.delegate as AnyObject?)?.responds(to: #selector(AppDelegate.newDocument(_:))) == true)
        #expect(buttons.map(\.title).suffix(3) == ["Open Folder…", "Open…", "New Note"])
    }

    /// File > New, typing, then the first save into the folder Settings > General names writes exactly what was
    /// typed; the next Cmd-S goes through the engine and writes exactly the text again.
    @Test func j1NewNoteTypedAndSavedWritesExactlyThoseBytes() async throws {
        let vault = try Vault([:])
        defer { vault.remove() }
        // What AppDelegate.newDocument does, short of ordering the window front.
        let document = MarkdownDocument()
        document.engine = vault.engine
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? MainWindowController)
        let textView = try #require(controller.textView)
        // The test host's run loop never closes an event's undo group, so each keystroke groups by hand.
        textView.history.undoManager.groupsByEvent = false
        #expect(textView.string.isEmpty)
        #expect(controller.tabName == document.displayName)
        #expect(controller.window?.isVisible == false)

        let panel = NSSavePanel()
        #expect(document.prepareSavePanel(panel))
        #expect(panel.directoryURL?.standardizedFileURL == Preferences.shared.newFileFolder.standardizedFileURL)

        Self.type("# Groceries\nEggs, milk and bread.\n- [ ] oats", into: textView)
        let typed = "# Groceries\nEggs, milk and bread.\n- [ ] oats"
        #expect(textView.string == typed)
        #expect(document.isDocumentEdited)

        // The save panel's choice: the vault's folder.
        let url = vault.url("Groceries.md")
        try await Self.save(document, to: url, .saveAsOperation)
        #expect(try Data(contentsOf: url) == Data(typed.utf8))
        #expect(document.fileURL?.standardizedFileURL == url.standardizedFileURL)
        #expect(!document.isDocumentEdited)
        let live = try #require(document.live)
        #expect(live.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())

        textView.setSelectedRange(NSRange(location: NSMaxRange((textView.string as NSString).range(of: "bread.")), length: 0))
        Self.type(" And tea.", into: textView)
        try await Self.save(document, to: url, .saveOperation)
        #expect(try Data(contentsOf: url) == Data("# Groceries\nEggs, milk and bread. And tea.\n- [ ] oats".utf8))
        #expect(!document.isDocumentEdited)
        #expect(controller.window?.isVisible == false)
    }

    /// File > New in a folder window: the save panel starts in that folder, and with no Cmd-S the note saves itself as
    /// Untitled.md there 2 s after the last keystroke, then autosaves through the engine like any opened file.
    @Test func j1NewNoteInAFolderSavesItselfThere() async throws {
        let vault = try Vault(["Untitled.md": "taken\n"])
        defer { vault.remove() }
        let document = MarkdownDocument()
        document.engine = vault.engine
        NSDocumentController.shared.addDocument(document)
        let controller = MainWindowController(folder: Folder(vault.notes))
        controller.display(document)
        defer { document.close() }
        let textView = try #require(controller.textView)
        textView.history.undoManager.groupsByEvent = false
        let panel = NSSavePanel()
        #expect(document.prepareSavePanel(panel))
        #expect(panel.directoryURL?.standardizedFileURL == vault.notes.standardizedFileURL)

        Self.type("# Groceries\nEggs.", into: textView)
        #expect(document.fileURL == nil)
        let url = vault.url("Untitled 2.md")
        try await Self.until { document.fileURL != nil && document.live != nil }
        #expect(document.fileURL?.standardizedFileURL == url.standardizedFileURL)
        #expect(try Data(contentsOf: url) == Data("# Groceries\nEggs.".utf8))
        #expect(vault.text("Untitled.md") == "taken\n")
        #expect(!document.isDocumentEdited)

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        Self.type(" Milk.", into: textView)
        try await Self.until { vault.text("Untitled 2.md") == "# Groceries\nEggs. Milk." }
        #expect(controller.window?.isVisible == false)
    }

    /// The first launch writes Welcome.md into the notes folder and opens a window on that folder with the guide open
    /// and the caret at its end. A second launch leaves the guide, and anything typed in it, alone.
    @Test func j1FirstLaunchOpensWelcomeInTheNotesFolder() async throws {
        let vault = try Vault([:])
        defer { vault.remove() }
        let folder = vault.notes.appending(path: "Dewline", directoryHint: .isDirectory)
        #expect(try Welcome.write(in: folder))
        let guide = try String(contentsOf: Welcome.url(in: folder), encoding: .utf8)
        #expect(guide == (try String(contentsOf: Welcome.bundled, encoding: .utf8)))
        #expect(guide.hasPrefix("# Welcome to Dewline\n\nThis note is a file: Welcome.md, in the Dewline folder in Documents."))
        #expect(guide.contains(Welcome.paragraph + " \u{2318}-click to try it: [Show me a change](dewline://demo)"))
        #expect(!guide.contains("\u{2014}") && !guide.contains("--"))

        let controller = AppDelegate.welcomeWindow(in: folder)
        defer { Self.close(controller) }
        #expect(controller.folder?.url.standardizedFileURL == folder.standardizedFileURL)
        let textView = try #require(controller.textView)
        #expect(textView.string == guide)
        #expect(textView.selectedRange() == NSRange(location: (guide as NSString).length, length: 0))
        #expect(controller.window?.isVisible == false)

        try Data("# Mine\n".utf8).write(to: Welcome.url(in: folder))
        #expect(try Welcome.write(in: folder) == false)
        #expect(vault.text("Dewline/Welcome.md") == "# Mine\n")
    }

    /// Show me a change: Demo's claimed write lands one marked change inside the paragraph that holds the link, and
    /// the Keep bar names it; Keep ends the demo.
    @Test func j1ShowMeAChangeLandsInTheParagraphWithTheLink() async throws {
        let vault = try Vault([:])
        defer { vault.remove() }
        try Welcome.write(in: vault.notes)
        let tab = try Tab(Welcome.url(in: vault.notes), engine: vault.engine)
        defer { tab.close() }
        WelcomeDemo.play(tab.document, at: Welcome.url(in: vault.notes))
        try await Self.until { tab.marked.count == 1 }
        let change = try #require(tab.marked.first)
        guard case .agent(.demo, _) = change.change.origin else { Issue.record("Demo didn't write it: \(change.change.origin)"); return }
        let paragraph = (tab.textView.string as NSString).paragraphRange(for: change.change.range)
        #expect((tab.textView.string as NSString).substring(with: paragraph).contains("dewline://demo"))
        #expect(tab.textView.string.contains(Welcome.paragraph + Welcome.addition))
        let bar = KeepBar()
        bar.attach(to: tab.textView)
        #expect(bar.accessibilityLabel() == "Demo changed 1 place, change 1 of 1")
        tab.textView.keepChange(nil)
        #expect(tab.marked.isEmpty)
        #expect(!bar.shown)
    }

    /// File > New Note makes "Untitled.md" in the folder at once, then "Untitled 2.md"; once it saves with a first
    /// line, the note takes that line as its name, once, and the open document follows the file.
    @Test func j1NewNoteIsMadeInTheFolderAndNamedByItsFirstLine() async throws {
        let vault = try Vault(["Launch plan.md": "# Taken\n"])
        defer { vault.remove() }
        let url = try FileActions.newNote(in: vault.notes)
        #expect(url.lastPathComponent == "Untitled.md")
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(try FileActions.newNote(in: vault.notes).lastPathComponent == "Untitled 2.md")

        let controller = MainWindowController(folder: Folder(vault.notes))
        defer { Self.close(controller) }
        controller.open(url, newTab: false)
        let document = try #require(controller.document as? MarkdownDocument)
        let textView = try #require(controller.textView)
        textView.history.undoManager.groupsByEvent = false
        Self.type("# Launch plan\nShip it.", into: textView)
        try await Self.save(document, to: url)
        #expect(FileActions.nameIfUntitled(document))
        let named = vault.url("Launch plan 2.md")
        #expect(document.fileURL?.standardizedFileURL == named.standardizedFileURL)
        #expect(vault.text("Launch plan 2.md") == "# Launch plan\nShip it.")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Named once: a later first line leaves it.
        #expect(FileActions.nameIfUntitled(document))
        #expect(document.fileURL?.lastPathComponent == "Launch plan 2.md")

        #expect(FileActions.title(of: "\n  ## Q3: plans/goals\nbody") == "Q3 plansgoals")
        #expect(FileActions.title(of: "- [ ] ") == "[ ]")
        #expect(FileActions.title(of: "   \n") == nil)
        #expect(FileActions.title(of: String(repeating: "a", count: 80))?.count == 60)
    }

    // MARK: J2 A vault: Quick Open, wikilinks, back and forward

    private static let obsidianVault = [
        "Home.md": "# Home\n\nStart with [[Project Plan]], then [[Old#Notes]].\n",
        "Projects/Project Plan.md": "# Project Plan\n\n## Goals\n\nShip the beta.\n",
        "Archive/2025/Old.md": "# Old\n\nFirst things.\n\n## Notes\n\nKept for later.\n",
        "Journal/Daily.md": "# Daily\n",
        ".obsidian/app.json": "{}\n",
        ".obsidian/templates/Daily.md": "# Template\n",
        ".obsidian/templates/Project Plan.md": "# Template plan\n",
    ]

    /// An Obsidian vault opens as a folder: Quick Open finds a nested note by part of its name and never lists
    /// .obsidian; a wikilink opens its note in the same tab, a heading link puts the caret on the heading, and Back and
    /// Forward return to each file where it was left.
    @Test func j2VaultQuickOpenWikilinksAndBack() async throws {
        let vault = try Vault(Self.obsidianVault)
        defer { vault.remove() }
        let folder = Folder(vault.notes)
        let index = FolderIndex.of(folder)
        for _ in 0..<100 where index.files == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let files = try #require(index.files)
        #expect(Set(files.map(\.text.string)) == ["Home.md", "Projects/Project Plan.md", "Archive/2025/Old.md", "Journal/Daily.md"])
        let found = try #require(QuickOpen.rank("proj pl", in: files)?.first)
        #expect(found.file.text.string == "Projects/Project Plan.md")
        #expect(try #require(QuickOpen.rank("dai", in: files)).map(\.file.text.string) == ["Journal/Daily.md"])

        let controller = MainWindowController(folder: folder)
        defer { Self.close(controller) }
        controller.open(vault.url("Home.md"), newTab: false)
        let home = try #require(controller.textView)
        #expect(home.string == Self.obsidianVault["Home.md"])
        try await Self.until { home.styler.map.parsed >= home.textStorage!.length }
        home.setSelectedRange(NSRange(location: 3, length: 0))

        // Cmd-click the wikilink.
        let link = (home.string as NSString).range(of: "Project Plan]]").location
        #expect(home.follow(at: try Self.point(of: link + 1, in: home)))
        let plan = try #require(controller.textView)
        #expect(plan !== home)
        #expect((controller.document as? NSDocument)?.fileURL?.lastPathComponent == "Project Plan.md")
        #expect(plan.string.hasPrefix("# Project Plan"))
        // One document per tab: Home closed as Plan replaced it.
        #expect(NSDocumentController.shared.document(for: vault.url("Home.md")) == nil)

        controller.goBack(nil)
        let back = try #require(controller.textView)
        #expect((controller.document as? NSDocument)?.fileURL?.lastPathComponent == "Home.md")
        #expect(back.selectedRange().location == 3)
        #expect(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: "")))
        controller.goForward(nil)
        #expect((controller.document as? NSDocument)?.fileURL?.lastPathComponent == "Project Plan.md")
        controller.goBack(nil)

        // A heading link opens the note found by name, deeper in the tree, with the caret on the heading.
        let again = try #require(controller.textView)
        try await Self.until { again.styler.map.parsed >= again.textStorage!.length }
        let old = (again.string as NSString).range(of: "Old#Notes").location
        #expect(again.follow(at: try Self.point(of: old + 1, in: again)))
        let notes = try #require(controller.textView)
        #expect((controller.document as? NSDocument)?.fileURL?.lastPathComponent == "Old.md")
        #expect(notes.selectedRange().location == (notes.string as NSString).range(of: "## Notes").location)

        // Wikilinks never resolve into .obsidian, and a missing note would be made in the vault itself.
        #expect(Links.target(ofWikilink: "Daily", in: vault.notes) == .note(vault.url("Journal/Daily.md").standardizedFileURL, heading: nil))
        #expect(Links.target(ofWikilink: "Nowhere", in: vault.notes) == .missing(vault.url("Nowhere.md").standardizedFileURL))
        #expect(Links.target(ofWikilink: "../outside", in: vault.notes) == .refused)

        // Return in Quick Open opens the found note in this tab.
        controller.open(found.file.url, newTab: false)
        #expect((controller.document as? NSDocument)?.fileURL?.lastPathComponent == "Project Plan.md")
        #expect(controller.tabs.tabs.count == 1)
        #expect(controller.window?.isVisible == false)
    }

    /// The sidebar's file commands, with ⌘Z: New Folder, Rename (the open note follows), Move, Duplicate, and Move
    /// to Trash, which closes the note and comes back from the Trash on undo.
    @Test func j2FileActionsMakeRenameMoveDuplicateAndTrashUndoably() async throws {
        let vault = try Vault(["plan.md": "# Plan\n"])
        defer { vault.remove() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        func step(_ body: () throws -> Void) rethrows {
            undo.beginUndoGrouping()
            defer { undo.endUndoGrouping() }
            try body()
        }
        let controller = MainWindowController(folder: Folder(vault.notes))
        defer { Self.close(controller) }
        controller.open(vault.url("plan.md"), newTab: false)
        let document = try #require(controller.document as? MarkdownDocument)

        var folder = vault.notes
        try step { folder = try FileActions.newFolder(in: vault.notes, undo: undo) }
        #expect(folder.lastPathComponent == "New Folder")
        var renamed = vault.notes
        try step { renamed = try FileActions.rename(vault.url("plan.md"), to: "Launch: plan/v2", undo: undo) }
        #expect(renamed.lastPathComponent == "Launch planv2.md")
        #expect(document.fileURL?.standardizedFileURL == renamed.standardizedFileURL)
        var moved = vault.notes
        try step { moved = try FileActions.move(renamed, to: folder, undo: undo) }
        #expect(moved.path.hasSuffix("New Folder/Launch planv2.md"))
        #expect(document.fileURL?.standardizedFileURL == moved.standardizedFileURL)
        undo.undo()
        #expect(document.fileURL?.standardizedFileURL == renamed.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        undo.undo()
        #expect(vault.text("plan.md") == "# Plan\n")
        #expect(document.fileURL?.lastPathComponent == "plan.md")

        let copy = try FileActions.duplicate(vault.url("plan.md"))
        #expect(copy.lastPathComponent == "plan copy.md")
        #expect(try FileActions.duplicate(vault.url("plan.md")).lastPathComponent == "plan copy 2.md")

        var trashed: URL?
        try step { trashed = try FileActions.trash(copy, undo: undo) }
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        undo.undo()
        #expect(vault.text("plan copy.md") == "# Plan\n")
        // Trashing an open note closes it first.
        try step { trashed = try FileActions.trash(vault.url("plan.md"), undo: undo) }
        #expect(NSDocumentController.shared.document(for: vault.url("plan.md")) == nil)
        undo.undo()
        #expect(vault.text("plan.md") == "# Plan\n")
        #expect(throws: (any Error).self) { try FileActions.rename(vault.url("plan.md"), to: " / ") }
    }

    /// The middle of the character at `index`, in the text view, as a click would hit it.
    private static func point(of index: Int, in textView: EditorTextView) throws -> NSPoint {
        let window = try #require(textView.window)
        let screen = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        let rect = textView.convert(window.convertFromScreen(screen), from: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// Closes every tab in the controller's window and its documents.
    private static func close(_ controller: MainWindowController) {
        for tab in controller.tabs.tabs {
            if let document = tab.document as? NSDocument {
                document.close()
            } else {
                tab.close()
            }
        }
    }

    // MARK: J3 Reviewing what an agent changed

    private static let plan = "# Plan\n\nAlpha line.\n\nUnchanged one.\n\nBravo line.\n\nUnchanged two.\n\nCharlie line.\n\nUnchanged three.\n\nDelta line.\n"
    private static let agentPlan = plan
        .replacingOccurrences(of: "Alpha line.", with: "Alpha line, revised.")
        .replacingOccurrences(of: "Bravo line.", with: "Bravo line, revised.")
        .replacingOccurrences(of: "Charlie line.", with: "Charlie line, revised.")
        .replacingOccurrences(of: "Delta line.", with: "Delta line, revised.")

    /// Claude Code rewrites the open file and two closed ones. The open file's four changes land marked with Claude's
    /// name, the Keep bar counts them and the Changes tab lists each line with its changed words in bold, and Keep,
    /// Revert and Keep All decide them: Keep and Revert act on the Keep bar's change when the caret is elsewhere, the
    /// file's bytes follow each decision, the decisions log holds one line per decision without the text, and nothing
    /// is left to review. The closed files are listed as changed while closed, and one opens with Claude's write
    /// marked.
    @Test func j3AnAgentsChangesAreReviewedKeptAndReverted() async throws {
        let vault = try Vault(["plan.md": Self.plan, "a.md": "# A\n\nOld a.\n", "b.md": "# B\n\nOld b.\n"])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        let claude = ChangeEngine.Origin.agent(.claude, session: "s1")
        ClosedChanges.engine = vault.engine
        defer { ClosedChanges.engine = MarkdownDocument.sharedEngine }

        try await Self.agentWrite(Self.agentPlan, to: vault.url("plan.md"), id: "toolu_1", engine: vault.engine)
        try await Self.agentWrite("# A\n\nNew a.\n", to: vault.url("a.md"), id: "toolu_2", engine: vault.engine)
        try await Self.agentWrite("# B\n\nNew b.\n", to: vault.url("b.md"), id: "toolu_3", engine: vault.engine)
        try await Self.until { tab.marked.count == 4 && tab.marked.allSatisfy { $0.change.origin == claude } }
        #expect(tab.textView.string == Self.agentPlan)
        #expect(!tab.document.isDocumentEdited)
        let files = Review.files(in: tab.window)
        #expect(Review.count(claude, in: files) == (places: 4, files: 1))
        #expect(Review.hasMarked(in: tab.window))
        #expect(tab.marked.map { tab.live.line($0.id) } == [3, 7, 11, 15])

        // The Keep bar says it once; the Changes tab lists the whole lines, each with its changed words in bold.
        let bar = KeepBar()
        bar.attach(to: tab.textView)
        #expect(bar.shown)
        #expect(bar.accessibilityLabel() == "Claude changed 4 places, change 1 of 4")
        Self.claim(.turnEnd, vault.engine)
        let review = ReviewViewController(for: tab.window)
        _ = review.view
        #expect(review.rows.count == 5)
        if case .note(_, let byline) = review.rows[0] { #expect(byline.hasPrefix("Claude Code \u{00B7} ")) } else { Issue.record("no note heading") }
        guard case .change(let live, let first, let text) = review.rows[1] else { Issue.record("no change row"); return }
        let line = ReviewViewController.line(of: first, in: live, text: text)
        #expect(line.string == "Alpha line, revised.")
        func weight(at index: Int) -> CGFloat {
            let font = line.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            return (font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        }
        #expect(weight(at: (line.string as NSString).range(of: ", revised").location) > weight(at: 0))

        // Keep with the caret outside every change keeps the Keep bar's change; then Revert the next from the caret.
        let changes = tab.marked
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(bar.focusedChange == changes[0].id)
        tab.textView.keepChange(nil)
        #expect(tab.marked.map(\.id) == [changes[1].id, changes[2].id, changes[3].id])
        #expect(bar.accessibilityLabel() == "Claude changed 3 places, change 1 of 3")
        tab.textView.setSelectedRange(NSRange(location: changes[1].change.range.location + 1, length: 0))
        tab.textView.revertChange(nil)
        #expect(tab.marked.map(\.id) == [changes[2].id, changes[3].id])
        tab.textView.keepAllChanges(nil)
        #expect(tab.marked.isEmpty)
        let expected = Self.agentPlan.replacingOccurrences(of: "Bravo line, revised.", with: "Bravo line.")
        #expect(tab.textView.string == expected)
        #expect(!bar.shown)
        review.reload()
        #expect(review.rows.isEmpty)
        #expect(Review.count(claude, in: files) == (places: 0, files: 0))
        #expect(!Review.hasMarked(in: tab.window))

        // The revert is an edit like any other: Cmd-S writes it.
        try await tab.save()
        #expect(try Data(contentsOf: vault.url("plan.md")) == Data(expected.utf8))

        let log = try String(contentsOf: vault.store.appending(path: "decisions.jsonl"), encoding: .utf8)
        let lines = log.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(lines.map { $0["decision"] as? String } == ["kept", "reverted", "kept", "kept"])
        #expect(lines.allSatisfy { $0["vendor"] as? String == "claude" && $0["session"] as? String == "s1" })
        #expect(lines.allSatisfy { $0["file"] as? String == Self.realpath(vault.url("plan.md")) })
        #expect(lines.allSatisfy { ($0["excerpt_hash"] as? String)?.count == 64 })
        #expect(!log.contains("revised"))

        // The closed files hold the agent's bytes and are listed; one opens with the write marked against the bytes it
        // replaced, and leaves the list.
        #expect(vault.text("a.md") == "# A\n\nNew a.\n")
        #expect(ClosedChanges.all.map { Self.realpath($0.url) } == ["a.md", "b.md"].map { Self.realpath(vault.url($0)) })
        #expect(ClosedChanges.all.allSatisfy { $0.origin == claude })
        let closed = try Tab(vault.url("a.md"), engine: vault.engine)
        defer { closed.close() }
        try await Self.until { closed.marked.count == 1 }
        #expect(closed.textView.string == "# A\n\nNew a.\n")
        #expect(closed.marked.first?.change.origin == claude)
        #expect(closed.marked.first.map { closed.live.excerpt($0.id) } == "New")
        #expect(!closed.document.isDocumentEdited)
        #expect(ClosedChanges.all.map { Self.realpath($0.url) } == [Self.realpath(vault.url("b.md"))])
        closed.textView.revertChange(nil)
        #expect(closed.textView.string == "# A\n\nOld a.\n")
        #expect(tab.window.isVisible == false)
    }

    // MARK: J4 Save, close, open again

    /// A saved file closes and opens again with its caret and scroll where they were, through the session as launch
    /// keeps it; opening writes nothing, and bytes Dewline doesn't render survive a save.
    @Test func j4SaveCloseReopenRestoresThePlaceAndOpeningWritesNothing() async throws {
        let long = "# Field Notes\n\n" + (1...240).map { "Paragraph \($0) of the field notes." }.joined(separator: "\n\n") + "\n"
        let odd = Data([0xEF, 0xBB, 0xBF]) + Data("# Odd\r\n\r\nTrailing spaces   \r\nA\ttab and  two spaces.\r\n".utf8)
        let vault = try Vault(["long.md": long])
        defer { vault.remove() }
        try vault.write("odd.md", odd)

        let first = try Tab(vault.url("long.md"), engine: vault.engine)
        first.textView.setSelectedRange(NSRange(location: first.location(of: "Paragraph 1 of"), length: 0))
        Self.type("Edited. ", into: first.textView)
        try await first.save()
        let saved = first.textView.string
        #expect(try String(contentsOf: vault.url("long.md"), encoding: .utf8) == saved)

        let target = first.location(of: "Paragraph 150 of")
        first.textView.setSelectedRange(NSRange(location: target + 4, length: 0))
        first.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        let clip = try #require(first.textView.enclosingScrollView?.contentView)
        let top = clip.bounds.minY
        #expect(top > 1000)
        let place = try #require(first.controller.place)
        #expect(place.caret == target + 4)

        // What quitting keeps and launching reads.
        let suite = "dev.arkwerx.dewline.tests.journey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Session(windows: [Session.Window(folder: nil, tabs: [Session.Tab(path: vault.url("long.md").path, place: place)], selected: 0)]).save(to: defaults)
        first.close()

        let before = try Self.stamp(vault.url("long.md"))
        let listing = vault.listing()
        let restored = try #require(Session.load(from: defaults)?.windows.first?.tabs.first)
        let second = try Tab(URL(filePath: restored.path), engine: vault.engine)
        defer { second.close() }
        second.controller.restore(restored.place)
        // The next frame lays the page out, as showing the window does.
        second.window.displayIfNeeded()
        #expect(second.textView.string == saved)
        #expect(second.textView.selectedRange() == NSRange(location: target + 4, length: 0))
        let reopened = try #require(second.textView.enclosingScrollView?.contentView)
        withKnownIssue("restore scrolls once to TextKit 2's estimated baseline, so the page settles paragraphs from its place") {
            #expect(abs(reopened.bounds.minY - top) < 1)
            #expect(second.controller.place?.top == place.top)
        }

        let third = try Tab(vault.url("odd.md"), engine: vault.engine)
        defer { third.close() }
        #expect(third.textView.string == "# Odd\r\n\r\nTrailing spaces   \r\nA\ttab and  two spaces.\r\n")
        try await Task.sleep(for: .milliseconds(400))
        #expect(try Self.stamp(vault.url("long.md")) == before)
        #expect(try Data(contentsOf: vault.url("odd.md")) == odd)
        #expect(vault.listing() == listing)
        #expect(!second.document.isDocumentEdited && !third.document.isDocumentEdited)

        // A save writes only the bytes typed: the byte-order mark, CRLF and spacing stay.
        third.textView.setSelectedRange(NSRange(location: third.location(of: "# Odd") + 5, length: 0))
        Self.type(" one", into: third.textView)
        try await third.save()
        #expect(try Data(contentsOf: vault.url("odd.md")) == Data([0xEF, 0xBB, 0xBF]) + Data("# Odd one\r\n\r\nTrailing spaces   \r\nA\ttab and  two spaces.\r\n".utf8))
        #expect(vault.listing() == listing)
    }

    /// The file's inode, modification time and bytes.
    private static func stamp(_ url: URL) throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return ["\(attributes[.systemFileNumber] ?? 0)", "\(date)", hex(try String(contentsOf: url, encoding: .utf8))]
    }

    // MARK: J5 git rewrites a paragraph you are editing

    /// You edit a paragraph while `git checkout` rewrites it. A conflict card opens under it; Cmd-S and autosave write
    /// nothing until you choose, and each choice writes its bytes.
    @Test(arguments: [ChangeEngine.Decision.keep, .other, .both])
    func j5GitRewritesTheParagraphYouAreEditing(_ decision: ChangeEngine.Decision) async throws {
        let ours = "# Plan\n\nShip on Friday.\n\nTell the team.\n"
        let theirs = "# Plan\n\nShip on Sunday.\n\nTell the team.\n"
        let vault = try Vault(["plan.md": ours], git: true)
        defer { vault.remove() }
        try vault.git("add", "plan.md")
        try vault.git("commit", "-q", "-m", "Friday")
        try vault.git("checkout", "-q", "-b", "rewrite")
        try vault.write("plan.md", theirs)
        try vault.git("commit", "-q", "-am", "Sunday")
        try vault.git("checkout", "-q", "-")
        #expect(vault.text("plan.md") == ours)

        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        tab.textView.insertText("Monday", replacementRange: NSRange(location: tab.location(of: "Friday"), length: 6))
        try vault.git("checkout", "-q", "rewrite")
        #expect(vault.text("plan.md") == theirs)
        try await Self.until { tab.live.changes.values.contains(where: \.conflict) }
        let (id, conflict) = try #require(tab.live.changes.first { $0.value.conflict })
        guard case .git = conflict.origin else { Issue.record("The conflict's writer is \(conflict.origin), not git"); return }
        #expect(tab.textView.string == "# Plan\n\nShip on Monday.\n\nTell the team.\n")

        await #expect(throws: SaveConflict.self) { try await tab.save() }
        #expect(await tab.live.autosave() == .conflict)
        #expect(vault.text("plan.md") == theirs)

        let card = try #require(tab.textView.marks.hangers[id]?.view as? ConflictCard)
        // "From git", Keep Yours first and filled, the keys in tooltips with Revert's and Keep's meaning.
        let labels = Self.views(in: card).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("From git") && labels.contains("Saving waits until you choose."))
        #expect([card.keepYours, card.useTheirs, card.keepBoth].map(\.title) == ["Keep Yours", "Use git\u{2019}s", "Keep Both"])
        #expect(card.keepYours.toolTip == "Keep Yours (\u{2325}\u{2318}\u{232B})" && card.useTheirs.toolTip == "Use git\u{2019}s (\u{2318}\u{21A9})")
        #expect(card.keepBoth.toolTip == nil)
        let expected: String
        switch decision {
        case .keep:
            expected = "# Plan\n\nShip on Monday.\n\nTell the team.\n"
            card.keepYours.performClick(nil)
        case .other:
            expected = theirs
            card.useTheirs.performClick(nil)
        case .both:
            // Yours, then theirs after it.
            let yours = (tab.textView.string as NSString).substring(with: conflict.range)
            expected = (tab.textView.string as NSString).replacingCharacters(
                in: conflict.range, with: yours + (yours.hasSuffix("\n") ? "" : "\n") + conflict.theirs)
            #expect(expected.contains("Ship on Monday.") && expected.contains("Ship on Sunday."))
            card.keepBoth.performClick(nil)
        }
        #expect(tab.textView.string == expected)
        try await Self.until { vault.text("plan.md") == expected }
        #expect(tab.live.changes.isEmpty)
    }

    /// On a conflict the change keys mean what they mean everywhere: Cmd-Return keeps the outside writer's text, here
    /// git's version, and Option-Cmd-Delete keeps yours.
    @Test(arguments: [true, false])
    func j5TheChangeKeysOnAConflict(_ keep: Bool) async throws {
        let ours = "# Plan\n\nShip on Friday.\n"
        let theirs = "# Plan\n\nShip on Sunday.\n"
        let vault = try Vault(["plan.md": ours])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        tab.textView.insertText("Monday", replacementRange: NSRange(location: tab.location(of: "Friday"), length: 6))
        try vault.write("plan.md", theirs)
        try await Self.until { tab.live.changes.values.contains(where: \.conflict) }
        let conflict = try #require(tab.live.changes.values.first { $0.conflict })
        tab.textView.setSelectedRange(NSRange(location: conflict.range.location + 1, length: 0))
        if keep { tab.textView.keepChange(nil) } else { tab.textView.revertChange(nil) }
        let expected = keep ? theirs : "# Plan\n\nShip on Monday.\n"
        #expect(tab.textView.string == expected)
        #expect(tab.live.changes.isEmpty)
        try await Self.until { vault.text("plan.md") == expected }
    }

    // MARK: J6 Earlier versions

    /// Every outside write leaves the version it replaced in File > Earlier Versions, and the buffer you hadn't saved
    /// when one merged in. Selecting a version shows what restoring it would change; Restore puts it in the buffer as
    /// one undoable edit, writing nothing to the file; Pin keeps it.
    @Test func j6EarlierVersionsShowWhatRestoringChangesAndRestore() async throws {
        let versions = ["# Plan\n", "# Plan\n\nOne.\n", "# Plan\n\nOne.\n\nTwo.\n"]
        let vault = try Vault(["plan.md": versions[0]])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        try Data(versions[1].utf8).write(to: vault.url("plan.md"))
        try await Self.until { tab.textView.string == versions[1] }
        try Data(versions[2].utf8).write(to: vault.url("plan.md"), options: .atomic)
        try await Self.until { tab.textView.string == versions[2] }
        // Typed and not saved when the next write merges in.
        tab.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        let typed = tab.textView.string
        let last = "# Plan\n\nOne.\n\nTwo.\n\nThree.\n"
        try Data(last.utf8).write(to: vault.url("plan.md"), options: .atomic)
        try await Self.until { tab.textView.string == "# Plan!\n\nOne.\n\nTwo.\n\nThree.\n" }
        try await Self.until { tab.live.snapshots.count >= 5 }

        let sheet = EarlierVersions(tab.document, tab.live)
        #expect(sheet.sheet.title == "Earlier Versions")
        #expect(EarlierVersions.title(of: tab.live.snapshots[0]).hasPrefix("Today, "))
        var seen: Set<String> = []
        for index in tab.live.snapshots.indices {
            await sheet.select(index)
            if let text = sheet.text { seen.insert(text) }
        }
        #expect(seen.isSuperset(of: versions + [typed, last]), "\(seen.sorted()) from \(tab.live.snapshots.map(\.origin))")

        // What restoring the first version would change: the lines it takes out are struck.
        let shown = EarlierVersions.difference(from: tab.textView.string, to: versions[0])
        #expect(shown.string.contains("Three."))
        let struck = shown.attribute(.strikethroughStyle, at: (shown.string as NSString).range(of: "Three.").location, effectiveRange: nil) as? Int
        #expect(struck == NSUnderlineStyle.single.rawValue)

        // The oldest version, restored as one undoable edit.
        await sheet.select(tab.live.snapshots.count - 1)
        let target = try #require(sheet.text)
        sheet.restoreSelected()
        try await Self.until { tab.textView.string == target }
        #expect(vault.text("plan.md") == last)
        #expect(tab.window.isVisible == false)
    }

    /// The sheet's diff of identical texts says so, and an empty history says there is nothing yet.
    @Test func j6EarlierVersionsSayWhenNothingDiffers() {
        #expect(EarlierVersions.difference(from: "# A\n", to: "# A\n").string == "Same as the current text.")
        #expect(EarlierVersions.writer(.external) == "Another app")
    }

    // MARK: J8 Export

    /// File > Export writes HTML and DOCX files of the open note, leaving the notes folder as it was.
    @Test func j8ExportWritesHTMLAndDOCX() async throws {
        let vault = try Vault(["plan.md": "# Plan\n\nShip on **Friday**.\n\n- [x] Draft\n- [ ] Review\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        let listing = vault.listing()
        let out = vault.root.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let html = out.appending(path: "plan.html")
        try await Export.write(tab.textView.string, title: "plan", as: .html, to: html, folder: vault.notes)
        let page = try String(contentsOf: html, encoding: .utf8)
        #expect(page.contains("<h1") && page.contains("<strong>Friday</strong>") && page.contains("<table>"))
        let docx = out.appending(path: "plan.docx")
        try await Export.write(tab.textView.string, title: "plan", as: .docx, to: docx, folder: vault.notes)
        let word = try Data(contentsOf: docx)
        #expect(word.starts(with: Data([0x50, 0x4B, 0x03, 0x04])))
        #expect(word.range(of: Data("word/document.xml".utf8)) != nil)
        #expect(vault.listing() == listing)
        #expect(Export.Format.allCases.map(\.type.preferredFilenameExtension) == ["html", "pdf", "docx"])
        #expect(Export.Format.allCases.map(\.name) == ["HTML", "PDF", "Word"])

        // One File > Export… on ⇧⌘E, starting on PDF, and Print on ⌘P; a written export is what the status bar names.
        let file = try #require(MainMenu.bar().main.items.first { $0.submenu?.title == "File" }?.submenu)
        let export = try #require(file.items.first { $0.title == "Export\u{2026}" })
        #expect(export.keyEquivalent == "E" && export.tag == Export.Format.pdf.rawValue)
        #expect(file.items.first { $0.title == "Print\u{2026}" }?.keyEquivalent == "p")
        #expect(!file.items.contains { $0.title.hasPrefix("Export as") })
        Export.exported(html)
        #expect(Export.lastExport == html)
    }

    // MARK: J9 Daily capture

    /// Capture adds a line to the inbox and closes; an empty line only closes. The Dock menu offers Capture, and
    /// Today's Note only while the daily note is on.
    @Test func j9CaptureAddsALineAndTheDockMenuOffersIt() throws {
        var added: [String] = []
        let capture = Capture()
        capture.append = { added.append($0) }
        capture.submit("  call the bank \n")
        capture.submit("   ")
        #expect(added == ["call the bank"])
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let dock = try #require(delegate.applicationDockMenu(NSApp))
        #expect(dock.items.map(\.title).prefix(2) == ["New Note", "Capture\u{2026}"])
        let file = try #require(MainMenu.bar().main.items.first { $0.submenu?.title == "File" }?.submenu)
        #expect(file.items.contains { $0.title == "Open Inbox" } && file.items.contains { $0.title == "Capture\u{2026}" })
    }

    /// The daily note is off by default; on, it opens once a day as Daily/2026-11-02.md in the notes folder.
    @Test func j9TheDailyNoteIsOffByDefaultAndOpensOncePerDay() throws {
        let suite = "dev.arkwerx.dewline.tests.journey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = try Vault([:])
        defer { vault.remove() }
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour) = (2026, 11, 2, 9)
        let day = try #require(Calendar.current.date(from: parts))
        #expect(!DailyNote.isOn(defaults: defaults) && !DailyNote.opensAtLaunch(defaults: defaults, now: day))
        defaults.set("firstLaunch", forKey: DailyNote.key)
        #expect(DailyNote.opensAtLaunch(defaults: defaults, now: day))
        let url = try DailyNote.today(in: vault.notes, now: day)
        #expect(url == vault.url("Daily/2026-11-02.md"))
        try Data("# Monday\n".utf8).write(to: url)
        #expect(try DailyNote.today(in: vault.notes, now: day) == url && vault.text("Daily/2026-11-02.md") == "# Monday\n")
        DailyNote.noteOpened(defaults: defaults, now: day)
        #expect(!DailyNote.opensAtLaunch(defaults: defaults, now: day))
        #expect(DailyNote.opensAtLaunch(defaults: defaults, now: day.addingTimeInterval(24 * 60 * 60)))
    }

    // MARK: Launch, hooks and tracking

    /// The launch window shows when nothing opened and either the setting asks for it or no session waits; the
    /// last session reopens otherwise.
    @Test func theLaunchDecisionFollowsTheSetting() throws {
        let suite = "dev.arkwerx.dewline.tests.journey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let one = Session(windows: [Session.Window(folder: "/tmp", tabs: [], selected: 0)])
        #expect(!Launch.shouldShowLaunchWindow(session: one, defaults: defaults, openWindows: 0))
        #expect(Launch.shouldShowLaunchWindow(session: Session(windows: []), defaults: defaults, openWindows: 0))
        #expect(Launch.shouldShowLaunchWindow(session: nil, defaults: defaults, openWindows: 0))
        #expect(!Launch.shouldShowLaunchWindow(session: nil, defaults: defaults, openWindows: 1))
        Preferences(defaults: defaults).onLaunch = .launchWindow
        #expect(Launch.shouldShowLaunchWindow(session: one, defaults: defaults, openWindows: 0))
    }

    /// Set Up reads which settings files lack hooks from `dewline doctor`, and runs the install on a terminal of its
    /// own, answering yes.
    @Test func hookSetupListsTheFilesAndAnswersOnATerminal() async throws {
        let report = "Version: app and command are both 0.1.0\n\nAgent hooks:\n  Claude Code: PreToolUse, Stop missing from /Users/a/.claude/settings.json\n  Codex: installed in /Users/a/.codex/hooks.json\n"
        #expect(HookSetup.missing(in: report) == [HookSetup.Missing(agent: "Claude Code", file: "/Users/a/.claude/settings.json")])
        let vault = try Vault([:])
        defer { vault.remove() }
        let script = vault.root.appending(path: "asks.sh")
        try Data("#!/bin/sh\n[ -t 0 ] || exit 3\nread answer\necho \"answered $answer\"\n".utf8).write(to: script)
        #expect(chmod(script.path, 0o755) == 0)
        let run = await HookSetup.run(script, [], answers: 1)
        #expect(run.ran)
        #expect(run.output.contains("answered y"))
    }

    /// A failure that switches tracking off is said once.
    @Test func trackingProblemsAreReportedOnce() {
        let before = Tracking.problems.count
        Tracking.report(.noSocket("Address already in use"))
        Tracking.report(.noSocket("Address already in use"))
        #expect(Tracking.problems.count == before + 1)
        #expect(Tracking.problems.last?.details.contains("Address already in use") == true)
    }

    // MARK: Menus

    /// Every menu bar command with a file open reaches something that handles it: its own target, or the responder
    /// chain from the text view through the window, its controller and document, then the app and its delegate.
    @Test func everyMenuCommandReachesAHandlerWithAFileOpen() throws {
        let vault = try Vault(["plan.md": "# Plan\n"])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        let chain = Self.chain(from: tab.textView)
        // The window that hosts the right pane, Share and the tab row answers these (ShellActions).
        let shell: Set<Selector> = [
            #selector(ShellActions.togglePreview(_:)), #selector(ShellActions.toggleAgent(_:)), #selector(ShellActions.toggleChanges(_:)),
            #selector(ShellActions.shareNote(_:)), #selector(ShellActions.reopenClosedTab(_:)),
        ]
        for (path, item) in Self.items(of: MainMenu.bar().main) {
            guard let action = item.action else { continue }
            let handlers: [AnyObject] = item.target.map { [$0 as AnyObject] } ?? chain
            withKnownIssue("MainWindowController answers ShellActions once the right pane lands", isIntermittent: true) {
                #expect(handlers.contains { $0.responds(to: action) }, "\(path) does nothing: no handler for \(action)")
            } when: {
                shell.contains(action)
            }
        }
        // New Tab reaches the tab's controller rather than stopping at a responder before it.
        #expect(chain.first { $0.responds(to: #selector(NSResponder.newWindowForTab(_:))) } === tab.controller)
    }

    /// View > Show Sidebar (Control-Cmd-S) goes up the responder chain from the text view, as the menu sends it, and
    /// collapses the sidebar; sending it again shows it.
    @Test func showSidebarFromTheMenuCollapsesTheSidebar() async throws {
        let vault = try Vault(["plan.md": "# Plan\n"])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        let split = try #require(tab.window.contentViewController as? NSSplitViewController)
        let sidebar = try #require(split.splitViewItems.first)
        let chain = Self.chain(from: tab.textView)
        #expect(Self.enabled(#selector(NSSplitViewController.toggleSidebar(_:)), in: chain))
        #expect(tab.textView.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil))
        try await Self.until { sidebar.isCollapsed }
        _ = tab.textView.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
        try await Self.until { !sidebar.isCollapsed }
    }

    /// The change commands are off with nothing marked and on with a change under the caret; Back, Forward and Find in
    /// Files are off where they would do nothing.
    @Test func commandsThatWouldDoNothingAreDisabled() async throws {
        let vault = try Vault(["plan.md": "# Plan\n\nShip on Friday.\n"])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        let chain = Self.chain(from: tab.textView)
        let changeCommands = [
            #selector(EditorTextView.keepChange(_:)), #selector(EditorTextView.revertChange(_:)), #selector(EditorTextView.keepAllChanges(_:)),
            #selector(EditorTextView.revertAllChanges(_:)), #selector(EditorTextView.nextChange(_:)), #selector(EditorTextView.previousChange(_:)),
        ]
        for action in changeCommands + [
            #selector(MainWindowController.goBack(_:)), #selector(MainWindowController.goForward(_:)),
            #selector(MainWindowController.findInFiles(_:)), #selector(MainWindowController.showNextTab(_:)),
            #selector(EditorTextView.unfoldAll(_:)),
        ] {
            #expect(Self.enabled(action, in: chain) == false, "\(action) is enabled with nothing to act on")
        }
        #expect(Self.enabled(#selector(EditorTextView.format(_:)), in: chain) == true)
        // A folder window with no file open has nothing to save or export.
        let empty = MainWindowController(folder: Folder(vault.notes))
        defer { empty.close() }
        let bare = Self.chain(from: try #require(empty.window?.contentView))
        for action in [#selector(MarkdownDocument.exportDocument(_:)), #selector(NSDocument.save(_:)), #selector(EditorTextView.keepAllChanges(_:))] {
            #expect(!Self.enabled(action, in: bare), "\(action) is enabled in a folder window with no file")
        }

        let after = "# Plan\n\nShip on Friday.\n\nAgent note.\n"
        try await Self.agentWrite(after, to: vault.url("plan.md"), id: "toolu_1", engine: vault.engine)
        try await Self.until { tab.marked.count == 1 }
        tab.textView.setSelectedRange(NSRange(location: tab.marked[0].change.range.location + 1, length: 0))
        for action in changeCommands {
            #expect(Self.enabled(action, in: chain) == true, "\(action) is disabled with a change under the caret")
        }
        // With the caret elsewhere the keys act on the Keep bar's change, as its buttons do.
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(Self.enabled(#selector(EditorTextView.keepChange(_:)), in: chain) == true)
        #expect(Self.enabled(#selector(EditorTextView.keepAllChanges(_:)), in: chain) == true)
        tab.textView.keepChange(nil)
        #expect(tab.marked.isEmpty)
        #expect(tab.textView.string == after)
        #expect(Self.enabled(#selector(EditorTextView.keepChange(_:)), in: chain) == false)
    }

    /// The keys follow the Keep bar's focus when the caret is in no change: the bar's change is the one decided.
    @Test func theChangeKeysFollowTheKeepBar() async throws {
        let vault = try Vault(["plan.md": Self.plan])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        try await Self.agentWrite(Self.agentPlan, to: vault.url("plan.md"), id: "toolu_1", engine: vault.engine)
        try await Self.until { tab.marked.count == 4 }
        let changes = tab.marked
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        tab.textView.revertChange(nil)
        #expect(tab.marked.map(\.id) == changes.dropFirst().map(\.id))
        #expect(tab.textView.string.contains("Alpha line.\n"))
        tab.textView.keepBarFocus = { changes[2].id }
        tab.textView.keepChange(nil)
        #expect(tab.marked.map(\.id) == [changes[1].id, changes[3].id])
    }

    /// The responders a menu command looks through, in AppKit's order, for a window that is never key.
    private static func chain(from first: NSResponder) -> [AnyObject] {
        var chain: [AnyObject] = []
        var responder: NSResponder? = first
        while let next = responder {
            chain.append(next)
            responder = next.nextResponder
        }
        let window = (first as? NSView)?.window
        let extra: [AnyObject?] = [window?.delegate, window?.windowController, window?.windowController?.document as AnyObject?, NSApp, NSApp.delegate, NSDocumentController.shared]
        for object in extra.compactMap({ $0 }) where !chain.contains(where: { $0 === object }) {
            chain.append(object)
        }
        return chain
    }

    /// Whether the menu item for `action` would be enabled: false without a handler, else what the handler validates.
    private static func enabled(_ action: Selector, tag: Int = 0, in chain: [AnyObject]) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag
        guard let handler = chain.first(where: { $0.responds(to: action) }) else { return false }
        if let validator = handler as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = handler as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    /// Every item in `menu` and its submenus with its path.
    private static func items(of menu: NSMenu, _ path: [String] = []) -> [(String, NSMenuItem)] {
        menu.items.flatMap { item -> [(String, NSMenuItem)] in
            if let submenu = item.submenu { return items(of: submenu, path + [submenu.title]) }
            return [((path + [item.title]).joined(separator: " › "), item)]
        }
    }

    // MARK: The test host

    /// The test host is a build of its own, so what a test opens lands in its defaults, Application Support and
    /// recent documents, never the app's.
    @Test func theTestHostKeepsItsOwnDefaults() throws {
        let id = try #require(Bundle.main.bundleIdentifier)
        #expect(id == "dev.arkwerx.dewline.testhost")
        let key = "JourneyTestHostProbe"
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(UserDefaults.standard.persistentDomain(forName: id)?[key] as? Bool == true)
        #expect(UserDefaults.standard.persistentDomain(forName: "dev.arkwerx.dewline")?[key] == nil)
    }

    // MARK: Error paths

    /// A file that is not UTF-8, and a path that is a FIFO, refuse to open at once and are never written; a file
    /// deleted while open stops autosave, and Cmd-S writes it again.
    @Test func filesThatCannotOpenAndAFileDeletedWhileOpen() async throws {
        let vault = try Vault(["plan.md": "# Plan\n"])
        defer { vault.remove() }
        let latin = Data("# Caf".utf8) + Data([0xE9, 0x0A])
        try vault.write("latin.md", latin)
        for engine in [vault.engine, nil] {
            #expect(throws: CocoaError.self) { try Self.read(vault.url("latin.md"), engine: engine) }
        }
        #expect(try Data(contentsOf: vault.url("latin.md")) == latin)
        #expect(mkfifo(vault.url("pipe.md").path, 0o600) == 0)
        for engine in [vault.engine, nil] {
            #expect(throws: CocoaError.self) { try Self.read(vault.url("pipe.md"), engine: engine) }
        }

        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        try FileManager.default.removeItem(at: vault.url("plan.md"))
        try await Task.sleep(for: .milliseconds(300))
        tab.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        #expect(await tab.live.autosave() == .deleted)
        #expect(!FileManager.default.fileExists(atPath: vault.url("plan.md").path))
        try await tab.save()
        #expect(vault.text("plan.md") == "# Plan!\n")
    }

    // MARK: Helpers

    /// Reads `url` into a new document as opening it does, with or without an engine.
    private static func read(_ url: URL, engine: ChangeEngine?) throws {
        let document = MarkdownDocument()
        document.engine = engine
        try document.read(from: url, ofType: type)
        document.close()
    }

    /// Types `text` a character at a time, Return as Return, each keystroke its own undo group when the text view's
    /// undo manager doesn't group by event.
    private static func type(_ text: String, into textView: EditorTextView) {
        let undo = textView.history.undoManager
        for character in text {
            if !undo.groupsByEvent { undo.beginUndoGrouping() }
            if character == "\n" {
                textView.insertNewline(nil)
            } else {
                textView.insertText(String(character), replacementRange: textView.selectedRange())
            }
            if !undo.groupsByEvent { undo.endUndoGrouping() }
        }
    }

    /// Cmd-S, or a Save As to `url`.
    private static func save(_ document: MarkdownDocument, to url: URL, _ operation: NSDocument.SaveOperationType = .saveOperation) async throws {
        let error: (any Error)? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: type, for: operation) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
    }

    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views)
    }

    private static func hex(_ text: String) -> String {
        contentHash(Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func realpath(_ url: URL) -> String {
        Darwin.realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? url.path
    }

    private static func until(within limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A hook's claim in Claude Code session s1, as `dewline notify` sends it.
    private static func claim(_ event: ControlSocket.Claim.Event, _ engine: ChangeEngine) {
        LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: event), engine: engine)
    }

    /// Claude Code's Write: PreToolUse with the hash it read and the one it declares, the new bytes to a temporary file
    /// beside the original renamed over it, then PostToolUse with the hash it wrote.
    private static func agentWrite(_ text: String, to url: URL, id: String, engine: ChangeEngine) async throws {
        let before = try String(contentsOf: url, encoding: .utf8)
        let path = realpath(url)
        claim(.preToolUse(.init(id: id, tool: .write, path: path, hash: hex(before), declared: hex(text))), engine)
        // The tool runs once its PreToolUse hook has returned.
        try await Task.sleep(for: .milliseconds(100))
        let temporary = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).tmp.\(getpid()).\(UInt64(Date().timeIntervalSince1970 * 1000))")
        try Data(text.utf8).write(to: temporary)
        #expect(Darwin.rename(temporary.path, url.path) == 0)
        claim(.postToolUse(.init(id: id, tool: .write, path: path, hash: hex(text), declared: nil)), engine)
    }

    /// A folder of notes under the temporary folder, by its resolved path as FSEvents and the wikilink search report
    /// it, and a change engine whose store sits beside the notes rather than in Application Support.
    @MainActor
    private final class Vault {
        let root: URL
        let notes: URL
        let engine: ChangeEngine

        init(_ files: [String: String], git: Bool = false) throws {
            root = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().appending(path: "dewline-journey-\(UUID().uuidString)")
            notes = root.appending(path: "notes", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            engine = try ChangeEngine(store: root.appending(path: "store"))
            for (path, text) in files { try write(path, text) }
            if git { try self.git("init", "-q") }
        }

        var store: URL { root.appending(path: "store") }

        func url(_ path: String) -> URL {
            notes.appending(path: path)
        }

        func write(_ path: String, _ text: String) throws {
            try write(path, Data(text.utf8))
        }

        func write(_ path: String, _ bytes: Data) throws {
            let url = url(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }

        func text(_ path: String) -> String? {
            try? String(contentsOf: url(path), encoding: .utf8)
        }

        /// git in the notes folder, with no system or global config and a HOME of its own.
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", notes.path, "-c", "user.name=Journey", "-c", "user.email=journey@example.invalid"] + arguments
            process.environment = ["HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": "/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        }

        /// Every entry under the notes folder, hidden ones included.
        func listing() -> [String] {
            let walk = FileManager.default.enumerator(atPath: notes.path)
            return (walk?.allObjects as? [String] ?? []).filter { !$0.hasPrefix(".git/") && $0 != ".git" }.sorted()
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A file open in a tab of its own through `engine`, as the app opens one, in a window that is never shown.
    /// Without a fileURL the tab leaves the recent files in user defaults alone.
    @MainActor
    private final class Tab {
        let url: URL
        let document = MarkdownDocument()
        let controller: MainWindowController

        init(_ url: URL, engine: ChangeEngine?) throws {
            self.url = url
            document.engine = engine
            try document.read(from: url, ofType: JourneyTests.type)
            document.makeWindowControllers()
            controller = try #require(document.windowControllers.first as? MainWindowController)
        }

        var textView: EditorTextView { controller.textView! }
        var live: LiveFile { document.live! }
        var window: NSWindow { controller.window! }

        func location(of text: String) -> Int {
            (textView.string as NSString).range(of: text).location
        }

        func save() async throws {
            try await JourneyTests.save(document, to: url)
        }

        /// The marked changes, top to bottom.
        var marked: [(id: UInt64, change: LiveFile.Change)] {
            live.changes.filter(\.value.marked).sorted { $0.value.range.location < $1.value.range.location }.map { ($0.key, $0.value) }
        }

        func close() {
            document.close()
        }
    }
}
