import AppKit
import MdCore
import Testing
@testable import Dewline

/// The agent panel against Fixtures/fake-acp-agent.py, a stand-in agent run with the system python3: no model, no
/// network. Notes open through the change engine in windows that are never shown.
@MainActor
@Suite(.serialized)
struct AgentPanelTests {
    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake-acp-agent.py")
    static let fake = AgentSpec(name: "Fake", command: "/usr/bin/python3", arguments: ["-I", fixture.path])

    @Test func aPromptStreamsTheAnswerWithTheNoteAndSelectionAsContext() async throws {
        let note = try Note("# Plan\n\nShip on Friday.\n")
        defer { note.close() }
        let chat = try await note.chat()
        defer { chat.end() }
        let reason = await chat.send("hello", note: note.url, selection: .init(text: "Ship", lines: 3...3))
        #expect(reason == "end_turn")
        #expect(chat.items.first == .user("hello", context: ["plan", "Selection (1 line)"]))
        #expect(chat.items.contains(.agent("Got text, resource_link, resource. Selection: Ship")))
        #expect(chat.state == .ready)
    }

    @Test func anAgentEditLandsAsAMarkedChangeThatReverts() async throws {
        let note = try Note("# Plan\n\nShip on Friday.\n")
        defer { note.close() }
        // Unsaved text: the agent reads the buffer, and the write keeps it.
        note.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        let chat = try await note.chat()
        defer { chat.end() }
        #expect(await chat.send("edit the date", note: note.url, selection: nil) == "end_turn")
        let origin = ChangeEngine.Origin.agent(.acp, session: chat.writes.session)
        try await until { note.live.changes.values.contains { $0.marked && $0.origin == origin } }
        #expect(note.textView.string == "# Plan!\n\nShip on Monday.\n")
        #expect(MarkWriter(origin).name == "Fake")
        #expect(chat.items.contains(.thought("Checking the dates.")))
        #expect(chat.items.contains(.plan([.init(content: "Read the note", status: "completed"), .init(content: "Move the launch to Monday", status: "in_progress")])))
        let tool = try #require(chat.items.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }.first)
        #expect(tool.status == "completed" && tool.kind == "edit")
        #expect(!chat.items.contains { if case .notice = $0 { true } else { false } })
        // Revert takes the change back out of the note, as for any agent's change.
        let id = try #require(note.live.changes.first { $0.value.marked }?.key)
        note.live.revert(id)
        #expect(note.textView.string == "# Plan!\n\nShip on Friday.\n")
    }

    @Test func pathsOutsideTheFolderAreRefused() async throws {
        let note = try Note("# Plan\n")
        defer { note.close() }
        let chat = try await note.chat()
        defer { chat.end() }
        await chat.send("outside", note: nil, selection: nil)
        #expect(chat.items.contains(.agent("Got text. Refused: /etc/hosts is outside the folder Dewline opened")))
        let writes = chat.writes
        #expect(throws: ACPClient.Failure.self) { try writes.resolve(note.files.path + "/../plan.md") }
        #expect(throws: ACPClient.Failure.self) { try writes.resolve("plan.md") }
        #expect(try writes.resolve(note.files.path + "/new.md").hasSuffix("/files/new.md"))
    }

    @Test func aPermissionPromptWaitsAndEscapeDeclines() async throws {
        let note = try Note("# Plan\n\nShip on Friday.\n")
        defer { note.close() }
        let chat = try await note.chat()
        defer { chat.end() }
        let turn = Task { await chat.send("edit with permission", note: note.url, selection: nil) }
        try await until { chat.items.contains { if case .ask = $0 { true } else { false } } }
        guard case .ask(let ask)? = chat.items.last else {
            Issue.record("no prompt")
            return
        }
        #expect(ask.text == "Fake wants to run `npm test` in files.")
        #expect(ask.options.map(\.label) == ["Allow Once", "Always Allow", "Don't Allow"])
        chat.choose(ask.id, option: nil)
        #expect(await turn.value == "end_turn")
        #expect(chat.items.contains(.agent(" Permission: no.")))
        #expect(note.textView.string == "# Plan\n\nShip on Friday.\n")
    }

    @Test func allowingLetsTheEditLand() async throws {
        let note = try Note("# Plan\n\nShip on Friday.\n")
        defer { note.close() }
        let chat = try await note.chat()
        defer { chat.end() }
        let turn = Task { await chat.send("edit with permission", note: note.url, selection: nil) }
        try await until { chat.items.contains { if case .ask = $0 { true } else { false } } }
        guard case .ask(let ask)? = chat.items.last else {
            Issue.record("no prompt")
            return
        }
        chat.choose(ask.id, option: "once")
        #expect(await turn.value == "end_turn")
        try await until { note.textView.string == "# Plan\n\nShip on Monday.\n" }
        #expect(note.live.changes.values.contains { $0.marked })
    }

    @Test func stopCancelsTheTurn() async throws {
        let note = try Note("# Plan\n")
        defer { note.close() }
        let chat = try await note.chat()
        defer { chat.end() }
        let turn = Task { await chat.send("wait", note: nil, selection: nil) }
        try await until { chat.state == .running && chat.items.count > 1 }
        chat.stop()
        #expect(await turn.value == "cancelled")
        #expect(chat.items.last == .notice("Stopped.", nil))
        #expect(chat.state == .ready)
    }

    @Test func anEditTheAgentMadeItselfIsCalledUnnamed() async throws {
        let note = try Note("# Plan\n\nShip on Friday.\n")
        defer { note.close() }
        let chat = try await note.chat()
        defer { chat.end() }
        await chat.send("self-write", note: note.url, selection: nil)
        #expect(chat.items.last == .notice("Fake wrote plan.md itself, so its change is marked as another app's. Set Up hooks to name it.", .setUpHooks))
    }

    @Test func aCrashOffersStartAgain() async throws {
        let note = try Note("# Plan\n")
        defer { note.close() }
        let chat = try await note.chat()
        defer { chat.end() }
        await chat.send("crash", note: nil, selection: nil)
        try await until { chat.state == .stopped }
        #expect(chat.items.last == .notice("Fake stopped.", .startAgain))
        await chat.start()
        #expect(chat.state == .ready)
    }

    @Test func anAgentThatNeedsSignInSaysSo() async throws {
        let note = try Note("# Plan\n")
        defer { note.close() }
        let chat = AgentChat(spec: Self.fake, folder: note.files, documents: { [note.document] })
        defer { chat.end() }
        chat.launch = { spec in
            AgentDiscovery.launch(spec).map { ($0.0, $0.1.merging(["FAKE_ACP_AUTH": "1"]) { $1 }) }
        }
        await chat.start()
        #expect(chat.state == .signIn)
    }

    // MARK: Discovery

    @Test func discoveryReadsTheLoginShellsAnswer() {
        let (path, specs) = AgentDiscovery.parse("/opt/homebrew/bin:/usr/bin:/bin\n/opt/homebrew/bin/gemini\n/Users/me/.npm/bin/claude-code-acp\n")
        #expect(path == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(specs == [
            AgentSpec(name: "Claude Code", command: "/Users/me/.npm/bin/claude-code-acp", arguments: []),
            AgentSpec(name: "Gemini CLI", command: "/opt/homebrew/bin/gemini", arguments: ["--acp"]),
        ])
        #expect(AgentDiscovery.parse("").specs.isEmpty)
    }

    @Test func addedAgentsAndTheLastOneUsedAreKept() throws {
        let name = "dev.arkwerx.dewline.tests.agents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        AgentDiscovery.add(name: "Mine", command: "my-agent", arguments: ["--acp"], defaults: defaults)
        AgentDiscovery.add(name: "Mine", command: "/usr/local/bin/my-agent", arguments: [], defaults: defaults)
        #expect(AgentDiscovery.added(defaults) == [AgentSpec(name: "Mine", command: "/usr/local/bin/my-agent", arguments: [])])
        let folder = URL(fileURLWithPath: "/tmp/Field Notes")
        AgentDiscovery.remember("Mine", in: folder, defaults: defaults)
        #expect(AgentDiscovery.last(in: folder, defaults: defaults) == "Mine")
        #expect(AgentSpec(name: "Codex", command: "codex-acp", arguments: []).signIn == "codex")
        #expect(AgentWrites.name(AgentWrites.session(agent: "Gemini CLI")) == "Gemini CLI")
        #expect(AgentWrites.writer(AgentWrites.session(agent: "Claude Code")) == .claude)
    }

    // MARK: The panel

    @Test func thePanelDrawsAnExchangeInLightAndDark() async throws {
        let note = try Note("# Launch plan\n\nShip on Friday.\nTell the team.\n")
        defer { note.close() }
        note.textView.setSelectedRange(NSRange(location: 15, length: 30))
        let (panel, window, defaults) = try Self.panel(note, agents: [Self.fake])
        defer { panel.endAll(); window.close(); defaults() }
        try await until { panel.chat?.state == .ready }
        #expect(panel.chips.arrangedSubviews.count == 2)
        let chat = try #require(panel.chat)
        let turn = Task { await chat.send("Move the launch to Monday. edit with permission", note: note.url, selection: panel.selectionChip) }
        try await until { chat.items.contains { if case .ask = $0 { true } else { false } } }
        try Self.render(panel.view, window, "agent-panel-ask")
        guard case .ask(let ask)? = chat.items.last else {
            Issue.record("no prompt")
            return
        }
        chat.choose(ask.id, option: "once")
        #expect(await turn.value == "end_turn")
        try await until { panel.places(chat.items.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }[0], chat: chat) > 0 }
        panel.redrawTools()
        try Self.render(panel.view, window, "agent-panel")
    }

    @Test func thePanelWithNoAgentSaysHowToInstallOne() async throws {
        let note = try Note("# Plan\n")
        defer { note.close() }
        let (panel, window, defaults) = try Self.panel(note, agents: [])
        defer { panel.endAll(); window.close(); defaults() }
        try await until { !panel.empty.isHidden }
        let labels = panel.empty.subviews(of: NSTextField.self).map(\.stringValue)
        #expect(labels.contains("Chat with your coding agent"))
        #expect(labels.contains("npm install -g @google/gemini-cli"))
        #expect(panel.inputBox?.isHidden == true)
        try Self.render(panel.view, window, "agent-panel-empty")
    }

    @Test func returnSendsWithTheChipsAndShiftReturnAddsALine() async throws {
        let note = try Note("# Plan\n\nShip on Friday.\n")
        defer { note.close() }
        note.textView.setSelectedRange(NSRange(location: 8, length: 4))
        let (panel, window, defaults) = try Self.panel(note, agents: [Self.fake])
        defer { panel.endAll(); window.close(); defaults() }
        try await until { panel.chat?.state == .ready }
        func key(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        panel.input.string = "first"
        panel.input.setSelectedRange(NSRange(location: 5, length: 0))
        panel.input.keyDown(with: key(.shift))
        #expect(panel.input.string == "first\n")
        panel.input.string = "hello"
        panel.input.keyDown(with: key([]))
        #expect(panel.input.string.isEmpty)
        let chat = try #require(panel.chat)
        try await until { chat.state == .ready && chat.items.count > 1 }
        #expect(chat.items.first == .user("hello", context: ["plan", "Selection (1 line)"]))
        // The selection went with the message, so its chip goes; the note's stays.
        #expect(panel.chips.arrangedSubviews.count == 1)
    }

    /// The panel on `note`'s window, in an offscreen window that is never ordered front, with its own defaults.
    static func panel(_ note: Note, agents: [AgentSpec]) throws -> (AgentPanelController, NSWindow, () -> Void) {
        let name = "dev.arkwerx.dewline.tests.panel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let textView = note.textView
        let context = AgentContext(
            folder: { note.files }, note: { note.url }, selection: { AgentContext.selection(in: textView) }, documents: { [note.document] })
        let panel = AgentPanelController(context: context, window: nil)
        panel.defaults = defaults
        panel.lookUp = { _, _ in agents }
        // A folder's first open starts nothing, so these start as if the first agent was used here before.
        if let first = agents.first { AgentDiscovery.remember(first.name, in: note.files, defaults: defaults) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = panel
        window.setContentSize(NSSize(width: 380, height: 620))
        return (panel, window, { defaults.removePersistentDomain(forName: name) })
    }

    /// Writes the view to ux-v4/agent-panel/<name>-light.png and -dark.png.
    static func render(_ view: NSView, _ window: NSWindow, _ name: String) throws {
        let folder = URL.libraryDirectory.appending(path: "Caches/dev.arkwerx.dewline/ux-v4/agent-panel")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            (view as? AgentPaper)?.needsDisplay = true
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: "\(name)-\(look).png"))
        }
    }

    private func until(within limit: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A note the change engine opens in a folder of its own, in a window that is never shown.
    @MainActor
    final class Note {
        let folder: URL
        let files: URL
        let url: URL
        let document: MarkdownDocument
        let textView: EditorTextView
        let live: LiveFile

        init(_ text: String) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "dewline-agent-\(UUID().uuidString)")
            files = folder.appending(path: "files")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            url = files.appending(path: "plan.md")
            try Data(text.utf8).write(to: url)
            document = MarkdownDocument()
            document.engine = try ChangeEngine(store: folder.appending(path: "snapshots"))
            try document.read(from: url, ofType: "net.daringfireball.markdown")
            document.makeWindowControllers()
            textView = try #require(document.textView)
            live = try #require(document.live)
        }

        /// A chat with the fake agent in the note's folder, started.
        func chat() async throws -> AgentChat {
            let document = document
            let chat = AgentChat(spec: AgentPanelTests.fake, folder: files, documents: { [document] })
            await chat.start()
            #expect(chat.state == .ready)
            return chat
        }

        func close() {
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

extension NSView {
    /// Every descendant of type `T`.
    func subviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + $0.subviews(of: type) }
    }
}
