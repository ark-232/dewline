internal import DewlineFFIBindings
import Foundation

/// What an agent's documentation says it loads of a file, as of `agentFilesDate`: the first `lines` lines,
/// or the first `bytes` bytes.
public struct AgentLimit: Sendable, Equatable {
    public let agent: String
    public let lines: Int?
    public let bytes: Int?

    public init(agent: String, lines: Int?, bytes: Int?) {
        (self.agent, self.lines, self.bytes) = (agent, lines, bytes)
    }
}

/// Whether an agent loads the file at `url` as instructions, rules, skills, plans or memory, by the engine's dated list.
public func isAgentFile(_ url: URL) -> Bool {
    DewlineFFIBindings.isAgentFile(path: url.path)
}

/// The load limit documented by the agent that reads `url`, if the list has one.
public func agentLimit(for url: URL) -> AgentLimit? {
    agentFileLimit(path: url.path).map { limit in
        AgentLimit(agent: limit.agent, lines: limit.lines.map { Int(clamping: $0) }, bytes: limit.bytes.map { Int(clamping: $0) })
    }
}

/// The day the agent-file list and its limits were last checked against the agents' documentation, YYYY-MM-DD.
public var agentFilesDate: String {
    DewlineFFIBindings.agentFilesDate()
}
