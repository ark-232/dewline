import Foundation

/// One chat with one agent process in a folder: starts it over ACP, sends prompts with the note and selection as
/// context, keeps the transcript the panel draws, and answers the agent's file and permission requests.
@MainActor
final class AgentChat {
    enum State: Equatable {
        case starting, ready, running
        /// The agent needs its own sign-in first.
        case signIn
        /// The process ended; Start Again makes a new one.
        case stopped
        case failed(String)
    }

    struct Tool: Equatable {
        let id: String
        var title: String
        var kind: String
        var status: String
        /// The files it touches, as the agent names them.
        var paths: [String]
    }

    struct Step: Equatable {
        let content: String
        /// pending, in_progress or completed.
        let status: String
    }

    struct Ask: Equatable {
        struct Option: Equatable {
            let id: String
            let label: String
            let kind: String
        }

        let id: Int
        let text: String
        let options: [Option]
        /// The option chosen, or "cancelled"; nil while it waits.
        var answer: String?
    }

    enum Action: Equatable {
        case setUpHooks, startAgain
    }

    enum Item: Equatable {
        case user(String, context: [String])
        case agent(String)
        case thought(String)
        case tool(Tool)
        case plan([Step])
        case ask(Ask)
        case notice(String, Action?)
    }

    /// The selected text the prompt carries, with its lines counted from 1.
    struct Selection: Equatable {
        let text: String
        let lines: ClosedRange<Int>

        var label: String { lines.count == 1 ? "Selection (1 line)" : "Selection (\(lines.count) lines)" }
    }

    let spec: AgentSpec
    let folder: URL
    let writes: AgentWrites
    private(set) var items: [Item] = []
    private(set) var state: State = .starting {
        didSet { if state != oldValue { stateChanged() } }
    }
    /// An item changed or was added, by index.
    var itemChanged: (Int) -> Void = { _ in }
    var stateChanged: () -> Void = {}
    var launch: @MainActor (AgentSpec) -> (URL, [String: String])? = AgentDiscovery.launch

    private var client: ACPClient?
    private var session: String?
    private var embeddedContext = false
    private var asks: [Int: CheckedContinuation<String, Never>] = [:]
    private var nextAsk = 0
    /// Where the current turn's items start, so a plan replaces only this turn's plan.
    private var turnStart = 0

    init(spec: AgentSpec, folder: URL, documents: (@MainActor () -> [MarkdownDocument])? = nil) {
        self.spec = spec
        self.folder = folder
        writes = documents.map { AgentWrites(folder: folder, agent: spec.name, documents: $0) } ?? AgentWrites(folder: folder, agent: spec.name)
    }

    var folderName: String { FileManager.default.displayName(atPath: folder.path) }

    // MARK: Lifetime

    func start() async {
        client?.stop()
        state = .starting
        guard let (executable, environment) = launch(spec) else {
            state = .failed("Dewline can't find \(spec.command). Install it, then press Look Again.")
            return
        }
        let client = ACPClient(executable: executable, arguments: spec.arguments, environment: environment, folder: folder)
        self.client = client
        client.notified = { [weak self] method, params in
            if method == "session/update" { self?.update(params["update"] ?? .null) }
        }
        client.answer = { [weak self] method, params throws(ACPClient.Failure) in
            guard let self else { throw .ended }
            return try await self.answer(method, params)
        }
        client.ended = { [weak self] _ in self?.ended() }
        do {
            try client.start()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let hello = try await client.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": false],
                "clientInfo": ["name": "Dewline", "version": .string(version)],
            ])
            embeddedContext = hello["agentCapabilities"]?["promptCapabilities"]?["embeddedContext"]?.bool ?? false
            let opened = try await client.request("session/new", ["cwd": .string(folder.path), "mcpServers": []])
            guard let id = opened["sessionId"]?.string else { throw ACPClient.Failure.invalid("No session") }
            session = id
            state = .ready
        } catch let failure as ACPClient.Failure where failure.code == -32000 || failure.message.localizedCaseInsensitiveContains("auth") {
            state = .signIn
        } catch {
            guard self.client === client, state == .starting else { return }
            client.stop()
            state = .failed("\(spec.name) didn't start.")
        }
    }

    /// Ends the process, as when the window closes.
    func end() {
        resolveAsks()
        client?.stop()
        client = nil
    }

    private func ended() {
        resolveAsks()
        client = nil
        writes.endTurn()
        state = .stopped
        append(.notice("\(spec.name) stopped.", .startAgain))
    }

    // MARK: Turns

    /// Sends one message with the open note as a link and the selection as text; returns the turn's stop reason.
    @discardableResult
    func send(_ text: String, note: URL?, selection: Selection?) async -> String? {
        guard state == .ready, let client, let session else { return nil }
        var context: [String] = []
        var prompt: [JSON] = [["type": "text", "text": .string(text)]]
        if let note {
            context.append(note.deletingPathExtension().lastPathComponent)
            prompt.append(["type": "resource_link", "uri": .string(note.absoluteString), "name": .string(note.lastPathComponent)])
        }
        if let selection {
            context.append(selection.label)
            let lines = "lines \(selection.lines.lowerBound) to \(selection.lines.upperBound)"
            if embeddedContext, let note {
                prompt.append(["type": "resource", "resource": [
                    "uri": .string(note.absoluteString + "#L\(selection.lines.lowerBound)-L\(selection.lines.upperBound)"),
                    "mimeType": "text/markdown", "text": .string(selection.text),
                ]])
            } else {
                prompt.append(["type": "text", "text": .string("Selected \(lines):\n\(selection.text)")])
            }
        }
        append(.user(text, context: context))
        turnStart = items.count
        writes.beginTurn()
        state = .running
        defer {
            writes.endTurn()
            if state == .running { state = .ready }
        }
        do {
            let result = try await client.request("session/prompt", ["sessionId": .string(session), "prompt": .array(prompt)])
            let reason = result["stopReason"]?.string ?? "end_turn"
            if reason == "cancelled" { append(.notice("Stopped.", nil)) }
            if reason == "refusal" { append(.notice("\(spec.name) declined to answer.", nil)) }
            return reason
        } catch {
            return nil
        }
    }

    /// Stop or Cmd-.: waiting permission prompts answer cancelled, then the agent hears session/cancel.
    func stop() {
        guard state == .running, let session else { return }
        resolveAsks()
        client?.notify("session/cancel", ["sessionId": .string(session)])
    }

    /// The person's choice on a permission prompt; nil picks Don't Allow, as Esc does.
    func choose(_ ask: Int, option: String?) {
        guard let index = items.lastIndex(where: { if case .ask(let item) = $0 { item.id == ask } else { false } }),
            case .ask(var item) = items[index], item.answer == nil
        else { return }
        let rejects = item.options.filter { $0.kind.hasPrefix("reject") }
        let chosen = option ?? (rejects.first { $0.kind == "reject_once" } ?? rejects.first)?.id ?? "cancelled"
        item.answer = chosen
        items[index] = .ask(item)
        itemChanged(index)
        asks.removeValue(forKey: ask)?.resume(returning: chosen)
    }

    private func resolveAsks() {
        for (id, continuation) in asks {
            asks[id] = nil
            if let index = items.lastIndex(where: { if case .ask(let item) = $0 { item.id == id } else { false } }),
                case .ask(var item) = items[index]
            {
                item.answer = "cancelled"
                items[index] = .ask(item)
                itemChanged(index)
            }
            continuation.resume(returning: "cancelled")
        }
    }
}

extension AgentChat {
    // MARK: What the agent sends

    private func append(_ item: Item) {
        items.append(item)
        itemChanged(items.count - 1)
    }

    private func replace(_ index: Int, _ item: Item) {
        items[index] = item
        itemChanged(index)
    }

    /// One session/update: text and thoughts stream into the last item of their kind, tool calls and the plan update
    /// in place.
    func update(_ update: JSON) {
        let text = update["content"]?["text"]?.string ?? ""
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            if case .agent(let old) = items.last { replace(items.count - 1, .agent(old + text)) } else { append(.agent(text)) }
        case "agent_thought_chunk":
            if case .thought(let old) = items.last { replace(items.count - 1, .thought(old + text)) } else { append(.thought(text)) }
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"]?.string else { return }
            let index = items.lastIndex { if case .tool(let tool) = $0 { tool.id == id } else { false } }
            var tool = index.flatMap { if case .tool(let tool) = items[$0] { tool } else { nil } }
                ?? Tool(id: id, title: "", kind: "other", status: "pending", paths: [])
            if let title = update["title"]?.string { tool.title = title }
            if let kind = update["kind"]?.string { tool.kind = kind }
            if let status = update["status"]?.string { tool.status = status }
            let paths = (update["locations"]?.array ?? []).compactMap { $0["path"]?.string }
                + (update["content"]?.array ?? []).compactMap { $0["type"]?.string == "diff" ? $0["path"]?.string : nil }
            for path in paths where !tool.paths.contains(path) { tool.paths.append(path) }
            if let index { replace(index, .tool(tool)) } else { append(.tool(tool)) }
            if tool.status == "completed", ["edit", "delete", "move"].contains(tool.kind) { checkUnmarked(tool) }
        case "plan":
            let steps = (update["entries"]?.array ?? []).map {
                Step(content: $0["content"]?.string ?? "", status: $0["status"]?.string ?? "pending")
            }
            let index = items.indices.last { index in
                guard index >= turnStart, case .plan = items[index] else { return false }
                return true
            }
            if let index {
                replace(index, .plan(steps))
            } else {
                append(.plan(steps))
            }
        default:
            break
        }
    }

    /// An edit the agent made on disk itself, not through Dewline, lands unmarked: the transcript says so once.
    private func checkUnmarked(_ tool: Tool) {
        for path in tool.paths {
            guard let real = try? writes.resolve(path), !writes.written.contains(real) else { continue }
            let name = (real as NSString).lastPathComponent
            let text = "\(spec.name) wrote \(name) itself, so the change isn't marked. Set Up hooks to mark it."
            guard !items.contains(.notice(text, .setUpHooks)) else { continue }
            append(.notice(text, .setUpHooks))
        }
    }

    /// A request from the agent: its file reads and writes, and permission prompts.
    func answer(_ method: String, _ params: JSON) async throws(ACPClient.Failure) -> JSON {
        switch method {
        case "fs/read_text_file":
            return try writes.read(params)
        case "fs/write_text_file":
            return try await writes.write(params)
        case "session/request_permission":
            let answer = await ask(params)
            return answer == "cancelled" ? ["outcome": ["outcome": "cancelled"]] : ["outcome": ["outcome": "selected", "optionId": .string(answer)]]
        default:
            throw .notFound
        }
    }

    private func ask(_ params: JSON) async -> String {
        guard state == .running else { return "cancelled" }
        let call = params["toolCall"] ?? .null
        let raw = (params["options"]?.array ?? []).compactMap { option -> Ask.Option? in
            guard let id = option["optionId"]?.string else { return nil }
            let kind = option["kind"]?.string ?? ""
            return Ask.Option(id: id, label: option["name"]?.string ?? id, kind: kind)
        }
        let rejectsOnce = raw.contains { $0.kind == "reject_once" }
        let options = raw.map { option in
            let label = switch option.kind {
            case "allow_once": "Allow Once"
            case "allow_always": "Always Allow"
            case "reject_once": "Don't Allow"
            case "reject_always": rejectsOnce ? "Never Allow" : "Don't Allow"
            default: option.label
            }
            return Ask.Option(id: option.id, label: label, kind: option.kind)
        }
        nextAsk += 1
        let id = nextAsk
        append(.ask(Ask(id: id, text: Self.askText(spec.name, call, folderName), options: options)))
        return await withCheckedContinuation { asks[id] = $0 }
    }

    /// "Claude Code wants to run `npm test` in Field Notes."
    static func askText(_ agent: String, _ call: JSON, _ folder: String) -> String {
        let command = call["rawInput"]?["command"]
        if let command = command?.string ?? command?.array.map({ $0.compactMap { $0.string }.joined(separator: " ") }) {
            return "\(agent) wants to run `\(command)` in \(folder)."
        }
        let title = call["title"]?.string ?? "use a tool"
        return "\(agent) wants to \(title.prefix(1).lowercased() + title.dropFirst()) in \(folder)."
    }
}
