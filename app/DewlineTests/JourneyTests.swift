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
        let actions = Self.views(in: window.contentView!).compactMap { $0 as? NSControl }.filter { $0.accessibilityRole() == .button }
        let new = try #require(actions.first { $0.accessibilityLabel() == "New Document" })
        #expect(new.action == #selector(AppDelegate.newDocument(_:)))
        #expect((NSApp.delegate as AnyObject?)?.responds(to: #selector(AppDelegate.newDocument(_:))) == true)
        #expect(actions.map { $0.accessibilityLabel() ?? "" }.prefix(3) == ["New Document", "Open…", "Open Folder…"])
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
    /// name, the finished line counts them, and Keep, Revert and Keep All decide them: the file's bytes follow each
    /// decision, the decisions log holds one line per decision without the text, and nothing is left to review.
    @Test func j3AnAgentsChangesAreReviewedKeptAndReverted() async throws {
        let vault = try Vault(["plan.md": Self.plan, "a.md": "# A\n\nOld a.\n", "b.md": "# B\n\nOld b.\n"])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        let claude = ChangeEngine.Origin.agent(.claude, session: "s1")

        try Self.agentWrite(Self.agentPlan, to: vault.url("plan.md"), id: "toolu_1", engine: vault.engine)
        try Self.agentWrite("# A\n\nNew a.\n", to: vault.url("a.md"), id: "toolu_2", engine: vault.engine)
        try Self.agentWrite("# B\n\nNew b.\n", to: vault.url("b.md"), id: "toolu_3", engine: vault.engine)
        try await Self.until { tab.marked.count == 4 && tab.marked.allSatisfy { $0.change.origin == claude } }
        #expect(tab.textView.string == Self.agentPlan)
        #expect(!tab.document.isDocumentEdited)
        let files = Review.files(in: tab.window)
        #expect(Review.count(claude, in: files) == (places: 4, files: 1))
        #expect(Review.hasMarked(in: tab.window))
        // Review Changes lists each by what it put there and its line; word-level changes read alike.
        #expect(tab.marked.map { tab.live.excerpt($0.id) } == Array(repeating: ", revised", count: 4))
        #expect(tab.marked.map { tab.live.line($0.id) } == [3, 7, 11, 15])

        // The turn ends: one quiet line under the tab bar.
        Self.claim(.turnEnd, vault.engine)
        try await Self.until { !tab.controller.finished.isHidden }
        #expect(tab.controller.finished.accessibilityLabel() == "Claude finished · 4 places in 1 file · Review")

        // Keep the first, Revert the second, from the caret as Cmd-Return and Option-Cmd-Delete do.
        let changes = tab.marked
        tab.textView.setSelectedRange(NSRange(location: changes[0].change.range.location + 1, length: 0))
        tab.textView.keepChange(nil)
        tab.textView.setSelectedRange(NSRange(location: changes[1].change.range.location + 1, length: 0))
        tab.textView.revertChange(nil)
        #expect(tab.marked.map(\.id) == [changes[2].id, changes[3].id])
        tab.textView.keepAllChanges(nil)
        #expect(tab.marked.isEmpty)
        let expected = Self.agentPlan.replacingOccurrences(of: "Bravo line, revised.", with: "Bravo line.")
        #expect(tab.textView.string == expected)
        try await Self.until { tab.controller.finished.isHidden }
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

        // The closed files hold the agent's bytes and open with nothing to review: the engine sees only open files.
        #expect(vault.text("a.md") == "# A\n\nNew a.\n")
        let closed = try Tab(vault.url("a.md"), engine: vault.engine)
        defer { closed.close() }
        #expect(closed.textView.string == "# A\n\nNew a.\n")
        #expect(closed.live.changes.isEmpty)
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

    // MARK: J6 Snapshots

    /// Every outside write leaves the version it replaced in File > Snapshots, and the buffer you hadn't saved when one
    /// merged in; choosing an entry restores it into the buffer, as one edit, writing nothing to the file.
    @Test func j6ASnapshotPrecedesEveryOutsideWriteAndRestores() async throws {
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

        let menu = NSMenu()
        SnapshotsMenu.shared.fill(menu, from: tab.live)
        let entries = menu.items.filter { !$0.isAlternate && $0.action != nil }
        #expect(entries.count == tab.live.snapshots.count)
        #expect(menu.items.filter(\.isAlternate).allSatisfy { $0.title.hasPrefix("Pin ") })
        var restored: Set<String> = []
        for item in entries {
            menu.performActionForItem(at: menu.index(of: item))
            // The restore reads the store off the main thread.
            try await Task.sleep(for: .milliseconds(250))
            restored.insert(tab.textView.string)
            #expect(vault.text("plan.md") == last)
        }
        #expect(restored.isSuperset(of: versions + [typed, last]))
        #expect(tab.window.isVisible == false)
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
        for (path, item) in Self.items(of: MainMenu.bar().main) {
            guard let action = item.action else { continue }
            let handlers: [AnyObject] = item.target.map { [$0 as AnyObject] } ?? chain
            #expect(handlers.contains { $0.responds(to: action) }, "\(path) does nothing: no handler for \(action)")
        }
        // New Tab reaches the tab's controller rather than stopping at a responder before it.
        #expect(chain.first { $0.responds(to: #selector(NSResponder.newWindowForTab(_:))) } === tab.controller)
    }

    /// View > Show Sidebar (Control-Cmd-S) goes up the responder chain from the text view, as the menu sends it, and
    /// collapses the sidebar; the title band's button, which targets the split directly, does the same.
    @Test func showSidebarFromTheMenuCollapsesTheSidebar() async throws {
        let vault = try Vault(["plan.md": "# Plan\n"])
        defer { vault.remove() }
        let tab = try Tab(vault.url("plan.md"), engine: vault.engine)
        defer { tab.close() }
        let split = try #require(tab.window.contentViewController?.children.first as? NSSplitViewController)
        let sidebar = try #require(split.splitViewItems.first)
        let chain = Self.chain(from: tab.textView)
        withKnownIssue("NSSplitViewController answers no to toggleSidebar: without a sidebar-behavior item, so NSWindow takes it") {
            #expect(chain.first { $0.responds(to: #selector(NSSplitViewController.toggleSidebar(_:))) } === split)
            #expect(Self.enabled(#selector(NSSplitViewController.toggleSidebar(_:)), in: chain))
        }
        _ = tab.textView.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
        try await Task.sleep(for: .milliseconds(400))
        withKnownIssue("the menu's toggleSidebar: never reaches StationSplitController") {
            #expect(sidebar.isCollapsed)
        }
        let button = try #require(Self.views(in: tab.window.contentView!).compactMap { $0 as? NSControl }.first { $0.accessibilityLabel() == "Show or hide the sidebar" })
        let wasCollapsed = sidebar.isCollapsed
        button.performClick(nil)
        try await Self.until { sidebar.isCollapsed != wasCollapsed }
    }

    /// The change commands are off with nothing marked and on with a change under the caret; Back, Forward and Find in
    /// Files are off where they would do nothing; File > Snapshots says when there are none.
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
        let menu = NSMenu()
        SnapshotsMenu.shared.fill(menu, from: nil)
        #expect(menu.items.map(\.title) == ["No Snapshots"] && !menu.items[0].isEnabled)

        let after = "# Plan\n\nShip on Friday.\n\nAgent note.\n"
        try Self.agentWrite(after, to: vault.url("plan.md"), id: "toolu_1", engine: vault.engine)
        try await Self.until { tab.marked.count == 1 }
        tab.textView.setSelectedRange(NSRange(location: tab.marked[0].change.range.location + 1, length: 0))
        for action in changeCommands {
            #expect(Self.enabled(action, in: chain) == true, "\(action) is disabled with a change under the caret")
        }
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(Self.enabled(#selector(EditorTextView.keepChange(_:)), in: chain) == false)
        #expect(Self.enabled(#selector(EditorTextView.keepAllChanges(_:)), in: chain) == true)
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
    private static func agentWrite(_ text: String, to url: URL, id: String, engine: ChangeEngine) throws {
        let before = try String(contentsOf: url, encoding: .utf8)
        let path = realpath(url)
        claim(.preToolUse(.init(id: id, tool: .write, path: path, hash: hex(before), declared: hex(text))), engine)
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
