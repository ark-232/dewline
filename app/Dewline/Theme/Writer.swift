import Foundation

/// Everyone whose changes Dewline marks (D21). Each has a default color for a light page and a dark one, and the owner
/// may pick another hue; the name, the dashed underline of an unknown app and its hollow bead keep the meaning in any
/// hue.
enum Writer: String, CaseIterable, Identifiable, Sendable {
    case you, claude, codex, cursor, copilot, gemini, git, unknown, otherMac, collaborator

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
        case .unknown: "Unknown app"
        case .otherMac: "Your other Mac"
        case .collaborator: "Collaborator"
        }
    }

    /// The default color on a light page and on a dark one (synthesis 2.1, with the writers D21 adds).
    var standard: (light: OKLCH, dark: OKLCH) {
        switch self {
        case .you: (OKLCH(l: 0.55, c: 0.12, h: 230), OKLCH(l: 0.74, c: 0.11, h: 230))
        case .claude: (OKLCH(l: 0.60, c: 0.15, h: 45), OKLCH(l: 0.72, c: 0.14, h: 45))
        case .codex: (OKLCH(l: 0.50, c: 0.16, h: 295), OKLCH(l: 0.70, c: 0.14, h: 295))
        case .cursor: (OKLCH(l: 0.55, c: 0.13, h: 150), OKLCH(l: 0.74, c: 0.13, h: 150))
        case .copilot: (OKLCH(l: 0.52, c: 0.17, h: 325), OKLCH(l: 0.72, c: 0.15, h: 325))
        case .gemini: (OKLCH(l: 0.52, c: 0.16, h: 262), OKLCH(l: 0.72, c: 0.13, h: 262))
        case .git: (OKLCH(l: 0.46, c: 0.10, h: 105), OKLCH(l: 0.70, c: 0.11, h: 105))
        case .unknown: (OKLCH(l: 0.55, c: 0, h: 0), OKLCH(l: 0.70, c: 0, h: 0))
        case .otherMac: (OKLCH(l: 0.58, c: 0.10, h: 195), OKLCH(l: 0.74, c: 0.10, h: 195))
        case .collaborator: (OKLCH(l: 0.56, c: 0.20, h: 350), OKLCH(l: 0.72, c: 0.17, h: 350))
        }
    }

    /// The writer's colors in `pick`'s hue and chroma at the default lightness, so body text on its wash keeps its
    /// contrast; the default colors without a pick.
    func colors(_ pick: OKLCH?) -> (light: OKLCH, dark: OKLCH) {
        let standard = standard
        guard let pick else { return standard }
        let chroma = min(pick.c, 0.22)
        let ratio = standard.light.c > 0 ? standard.dark.c / standard.light.c : 1
        return (OKLCH(l: standard.light.l, c: chroma, h: pick.h), OKLCH(l: standard.dark.l, c: chroma * ratio, h: pick.h))
    }
}

/// A theme color too close to a writer's: the nearest one across the light slot's light tokens and the dark slot's
/// dark tokens, and the nearest hue that clears them all.
struct WriterClash {
    static let distance = 8.0

    let theme: Theme
    let token: Token
    let dark: Bool
    let deltaE: Double
    /// The writer's color at the nearest clear hue, same chroma; nil for a gray writer, whose hue changes nothing.
    let clearHue: OKLCH?
}
