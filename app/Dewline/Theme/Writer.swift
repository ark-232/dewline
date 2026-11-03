import Foundation

/// Everyone whose changes Dewline marks (D21). Every outside change marks in the accent and shows its writer by name;
/// collaborators draw in ink2.
enum Writer: String, CaseIterable, Identifiable, Sendable {
    case you, claude, codex, cursor, copilot, gemini, git, unknown, otherMac, collaborator
    /// An agent chatting in the agent panel, over the Agent Client Protocol; the change carries its own name.
    case agent
    /// Welcome.md's first-run demo; it has no row in Settings.
    case demo

    var id: Self { self }

    var name: String {
        switch self {
        case .you: "You"
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        case .gemini: "Gemini"
        case .git: "git"
        case .unknown: "Another app"
        case .otherMac: "Your other Mac"
        case .collaborator: "Collaborator"
        case .agent: "Agent"
        case .demo: "Demo"
        }
    }
}
