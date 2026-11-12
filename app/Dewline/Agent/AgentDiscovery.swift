import Foundation

/// An agent program the panel can start: what to run and how to show it.
struct AgentSpec: Equatable, Sendable, Codable {
    let name: String
    /// A path, or a name looked up on the login shell's PATH.
    let command: String
    let arguments: [String]

    /// What to run once in Terminal to sign in, for the agents Dewline knows.
    var signIn: String {
        AgentDiscovery.known.first { $0.spec.name == name }?.signIn ?? (command as NSString).lastPathComponent
    }
}

/// The agents the panel can talk to: the supported ones the login shell finds, then any added in Settings > Agents.
@MainActor
enum AgentDiscovery {
    struct Known: Sendable {
        let spec: AgentSpec
        /// The commands that start it, the current one first.
        let commands: [String]
        let install: String
        let signIn: String
    }

    /// In the order the panel prefers them. Claude Code and Codex speak ACP through adapters (agentclientprotocol.com);
    /// Gemini CLI speaks it itself.
    nonisolated static let known = [
        Known(
            spec: AgentSpec(name: "Claude Code", command: "claude-agent-acp", arguments: []),
            commands: ["claude-agent-acp", "claude-code-acp"],
            install: "npm install -g @agentclientprotocol/claude-agent-acp", signIn: "claude"),
        Known(
            spec: AgentSpec(name: "Codex", command: "codex-acp", arguments: []), commands: ["codex-acp"],
            install: "npm install -g @agentclientprotocol/codex-acp", signIn: "codex"),
        Known(
            spec: AgentSpec(name: "Gemini CLI", command: "gemini", arguments: ["--acp"]), commands: ["gemini"],
            install: "npm install -g @google/gemini-cli", signIn: "gemini"),
    ]

    private static let addedKey = "DewlineAgentPanelAgents"
    private static let lastKey = "DewlineAgentPanelLastAgent"

    /// The agents found by the last look, then the added ones.
    private(set) static var found: [AgentSpec] = []
    /// The login shell's PATH, which agents run with: a Mac app's own PATH lacks npm's folders.
    private(set) static var path: String?
    private(set) static var looked = false

    /// Asks the login shell where the supported agents are, once per launch unless `again`, 3 s at most.
    static func look(again: Bool = false, defaults: UserDefaults = .standard) async -> [AgentSpec] {
        if looked, !again { return found + added(defaults) }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let names = known.flatMap(\.commands).joined(separator: " ")
        let output = await run(shell, ["-l", "-c", "printenv PATH; command -v \(names); true"], timeout: .seconds(3))
        let (path, specs) = parse(output ?? "")
        self.path = path
        found = specs
        looked = true
        return found + added(defaults)
    }

    /// The PATH line and the supported agents in `command -v`'s answer.
    static func parse(_ output: String) -> (path: String?, specs: [AgentSpec]) {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let path = lines.first { $0.contains(":") }
        let paths = lines.filter { $0.hasPrefix("/") && !$0.contains(":") }
        let specs = known.compactMap { known -> AgentSpec? in
            for command in known.commands {
                if let hit = paths.first(where: { ($0 as NSString).lastPathComponent == command }) {
                    return AgentSpec(name: known.spec.name, command: hit, arguments: known.spec.arguments)
                }
            }
            return nil
        }
        return (path, specs)
    }

    /// Adds an agent for Settings > Agents, replacing one with the same name.
    static func add(name: String, command: String, arguments: [String], defaults: UserDefaults = .standard) {
        let spec = AgentSpec(name: name, command: command, arguments: arguments)
        let list = added(defaults).filter { $0.name != name } + [spec]
        defaults.set(try? JSONEncoder().encode(list), forKey: addedKey)
    }

    static func added(_ defaults: UserDefaults = .standard) -> [AgentSpec] {
        defaults.data(forKey: addedKey).flatMap { try? JSONDecoder().decode([AgentSpec].self, from: $0) } ?? []
    }

    /// The agent last used in `folder`.
    static func last(in folder: URL, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: lastKey) as? [String: String])?[folder.path]
    }

    static func remember(_ name: String, in folder: URL, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: lastKey) as? [String: String] ?? [:]
        all[folder.path] = name
        defaults.set(all, forKey: lastKey)
    }

    /// The executable and environment to start `spec` with: the command found on the login PATH.
    static func launch(_ spec: AgentSpec) -> (URL, [String: String])? {
        var environment = ProcessInfo.processInfo.environment
        if let path { environment["PATH"] = path }
        let folders = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        let candidates = spec.command.hasPrefix("/") ? [spec.command] : folders.map { "\($0)/\(spec.command)" }
        guard let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return (URL(fileURLWithPath: hit), environment)
    }

    /// Runs a command and returns its stdout, or nil when it fails or takes longer than `timeout`.
    private static func run(_ command: String, _ arguments: [String], timeout: Duration) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled, process.isRunning { process.terminate() }
        }
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        timer.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}
