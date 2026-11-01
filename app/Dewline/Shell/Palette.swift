import AppKit

/// A row the palette runs: a menu command, or a setting shown with its value.
@MainActor
struct PaletteCommand {
    enum Action {
        case menu(MenuCommand)
        /// Flips a setting; the palette stays open to show its new value.
        case toggle(() -> Void)
        /// Opens a second level of choices, previewed as the selection moves.
        case choose(() -> PaletteChoices)
    }

    let id: String
    /// "Edit" or "Settings", shown dim before the title.
    let group: String
    let title: String
    let symbol: String
    let aliases: [String]
    let keys: KeyEquivalent?
    /// A setting's current value, shown at the right.
    let value: (() -> String)?
    let action: Action
    let text: FuzzyText

    init(id: String, group: String, title: String, symbol: String, aliases: [String] = [], keys: KeyEquivalent? = nil,
         value: (() -> String)? = nil, action: Action) {
        self.id = id
        self.group = group
        self.title = title
        self.symbol = symbol
        self.aliases = aliases
        self.keys = keys
        self.value = value
        self.action = action
        text = FuzzyText(title)
    }

    init(_ command: MenuCommand) {
        let group = command.path.components(separatedBy: " › ").first ?? command.path
        let symbols = [
            "Dewline": "app", "File": "doc", "Edit": "pencil", "Format": "textformat", "View": "eye", "Go": "arrow.right",
            "Window": "macwindow", "Help": "questionmark.circle",
        ]
        self.init(
            id: "menu:\(command.path) › \(command.item.title)", group: group, title: command.item.title,
            symbol: symbols[group] ?? "command", aliases: command.aliases,
            keys: KeyEquivalent(command.item.keyEquivalent, command.item.keyEquivalentModifierMask), action: .menu(command))
    }

    var selector: Selector? {
        if case .menu(let command) = action { return command.item.action }
        return nil
    }

    /// The settings the palette reaches: the theme and appearance as second levels, the switches toggled in place.
    /// `dark` picks the theme slot the window in front shows.
    static func settings(dark: Bool) -> [PaletteCommand] {
        let store = ThemeStore.shared
        let preferences = Preferences.shared
        func onOff(_ on: Bool) -> String { on ? "On" : "Off" }
        let themes = Theme.all + Theme.devPack
        let appearances: [(ThemeStore.Appearance, String)] = [(.light, "Light"), (.dark, "Dark"), (.auto, "Auto")]
        return [
            PaletteCommand(
                id: "settings:theme", group: "Settings", title: "Theme…", symbol: "paintpalette", aliases: ["Colors"],
                value: { (dark ? store.darkTheme : store.lightTheme).name },
                action: .choose {
                    let current = dark ? store.darkTheme : store.lightTheme
                    return PaletteChoices(title: "Theme", symbol: "paintpalette", names: themes.map(\.name),
                                          current: themes.firstIndex(of: current) ?? 0) { index in
                        if dark { store.darkTheme = themes[index] } else { store.lightTheme = themes[index] }
                    }
                }),
            PaletteCommand(
                id: "settings:appearance", group: "Settings", title: "Appearance…", symbol: "circle.lefthalf.filled",
                aliases: ["Dark Mode", "Light Mode"],
                value: { appearances.first { $0.0 == store.appearance }?.1 ?? "" },
                action: .choose {
                    PaletteChoices(title: "Appearance", symbol: "circle.lefthalf.filled", names: appearances.map(\.1),
                                   current: appearances.firstIndex { $0.0 == store.appearance } ?? 2) { index in
                        store.appearance = appearances[index].0
                    }
                }),
            PaletteCommand(
                id: "settings:smartPunctuation", group: "Settings", title: "Smart Punctuation", symbol: "quote.opening",
                aliases: ["Smart Quotes"], value: { onOff(store.smartPunctuation) }, action: .toggle { store.smartPunctuation.toggle() }),
            PaletteCommand(
                id: "settings:vim", group: "Settings", title: "Vim Mode", symbol: "keyboard",
                value: { onOff(store.vimMode) }, action: .toggle { store.vimMode.toggle() }),
            PaletteCommand(
                id: "settings:headingStyle", group: "Settings", title: "Heading Style", symbol: "textformat.size",
                aliases: ["Editorial"], value: { store.headingStyle == .editorial ? "Editorial" : "Standard" },
                action: .toggle { store.headingStyle = store.headingStyle == .editorial ? .standard : .editorial }),
            PaletteCommand(
                id: "settings:showsIgnored", group: "Settings", title: "Show Ignored Files", symbol: "eye.slash",
                aliases: ["gitignore"], value: { onOff(preferences.showsIgnored) }, action: .toggle { preferences.showsIgnored.toggle() }),
        ]
    }
}

/// A setting's second level: its values by name, the one in effect, and how to apply one. Applying `current` again
/// restores it.
@MainActor
struct PaletteChoices {
    let title: String
    let symbol: String
    let names: [String]
    let current: Int
    let apply: (Int) -> Void
}

/// A palette command that matched the query, with the offsets of its title's matched letters, or the alias that
/// matched and its letters'.
@MainActor
struct PaletteHit {
    let command: PaletteCommand
    let positions: [Int]
    let alias: String?
    let aliasPositions: [Int]
}

@MainActor
enum PaletteRank {
    /// Commands matching `query`: an alias typed in full first, then title matches, alias matches and group matches,
    /// each by match quality, then the shorter title, then `frecency`, then the order given.
    static func rank(_ query: String, in commands: [PaletteCommand], frecency: [String: Double]) -> [PaletteHit] {
        let letters = FuzzyText.query(query)
        let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !letters.isEmpty else { return commands.map { PaletteHit(command: $0, positions: [], alias: nil, aliasPositions: []) } }
        var scored: [(tier: Int, score: Int, index: Int, hit: PaletteHit)] = []
        for (index, command) in commands.enumerated() {
            if let alias = command.aliases.first(where: { $0.lowercased() == typed }) {
                let hit = PaletteHit(command: command, positions: [], alias: alias, aliasPositions: Array(0..<alias.utf16.count))
                scored.append((0, 0, index, hit))
            } else if let match = command.text.forgivingMatch(letters) {
                scored.append((1, match.score, index, PaletteHit(command: command, positions: match.positions, alias: nil, aliasPositions: [])))
            } else if let (alias, match) = command.aliases.compactMap({ alias in FuzzyText(alias).forgivingMatch(letters).map { (alias, $0) } })
                .max(by: { $0.1.score < $1.1.score }) {
                scored.append((2, match.score, index, PaletteHit(command: command, positions: [], alias: alias, aliasPositions: match.positions)))
            } else if let match = FuzzyText(command.group).match(letters) {
                scored.append((3, match.score, index, PaletteHit(command: command, positions: [], alias: nil, aliasPositions: [])))
            }
        }
        scored.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.score != b.score { return a.score > b.score }
            let (x, y) = (a.hit.command, b.hit.command)
            if x.title.count != y.title.count { return x.title.count < y.title.count }
            let (p, q) = (frecency[x.id] ?? 0, frecency[y.id] ?? 0)
            if p != q { return p > q }
            return a.index < b.index
        }
        return scored.map(\.hit)
    }
}

/// The commands run from the palette: the last five, and how often and how lately each ran.
@MainActor
enum PaletteHistory {
    private static let recentKey = "DewlinePaletteRecent"
    private static let usesKey = "DewlinePaletteUses"

    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    static func ran(_ id: String) {
        let defaults = UserDefaults.standard
        defaults.set(Array(([id] + recent.filter { $0 != id }).prefix(5)), forKey: recentKey)
        var uses = defaults.dictionary(forKey: usesKey) as? [String: [Double]] ?? [:]
        let count = uses[id]?.first ?? 0
        uses[id] = [count + 1, Date.now.timeIntervalSinceReferenceDate]
        if uses.count > 200, let oldest = uses.min(by: { ($0.value.last ?? 0) < ($1.value.last ?? 0) })?.key {
            uses[oldest] = nil
        }
        defaults.set(uses, forKey: usesKey)
    }

    /// Runs, each worth less by the day since the last one.
    static func frecency(now: Date = .now) -> [String: Double] {
        let uses = UserDefaults.standard.dictionary(forKey: usesKey) as? [String: [Double]] ?? [:]
        return uses.compactMapValues { use in
            guard use.count == 2 else { return nil }
            let days = max(now.timeIntervalSinceReferenceDate - use[1], 0) / 86_400
            return use[0] / (1 + days)
        }
    }
}

/// A heading the palette can go to: in the open file (`url` nil), or in a file of the folder.
struct PaletteHeading: Sendable {
    let url: URL?
    /// The file's name, shown dim beside a heading from the folder.
    let file: String
    let title: String
    let level: Int
    let line: Int

    /// The H1 to H3 headings of a Markdown file's text, past front matter and outside fenced code, as the outline
    /// lists them.
    static func scan(_ text: String, url: URL, file: String) -> [PaletteHeading] {
        var headings: [PaletteHeading] = []
        var inFrontMatter = false
        var fence: Character?
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if index == 0, line == "---" {
                inFrontMatter = true
            } else if inFrontMatter {
                inFrontMatter = line != "---" && line != "..."
            } else if let mark = fence {
                if line.hasPrefix(String(repeating: mark, count: 3)) { fence = nil }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = line.first
            } else if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(level)
                guard level <= 3, rest.isEmpty || rest.first == " " else { continue }
                let title = plainInline(String(rest.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)))
                if !title.isEmpty { headings.append(PaletteHeading(url: url, file: file, title: title, level: level, line: index + 1)) }
            }
        }
        return headings
    }

    /// The headings of every file in `urls`, read off the main thread; files over 1 MB are skipped.
    static func scan(_ urls: [URL], in folder: Folder?) async -> [PaletteHeading] {
        await Task.detached(priority: .userInitiated) {
            var headings: [PaletteHeading] = []
            for (index, url) in urls.enumerated() {
                if index % 64 == 0, Task.isCancelled { return headings }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= 1 << 20, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                headings += scan(text, url: url, file: folder?.relativePath(of: url) ?? url.lastPathComponent)
            }
            return headings
        }.value
    }

    /// The headings matching `query` by match quality, then in order; all of them for an empty query.
    static func rank(_ query: String, in headings: [PaletteHeading], limit: Int = 200) -> [(heading: PaletteHeading, positions: [Int])]? {
        let letters = FuzzyText.query(query)
        guard !letters.isEmpty else { return headings.prefix(limit).map { ($0, []) } }
        var matches: [(index: Int, score: Int, positions: [Int])] = []
        for (index, heading) in headings.enumerated() {
            if index % 2048 == 0, Task.isCancelled { return nil }
            if let match = FuzzyText(heading.title).forgivingMatch(letters) { matches.append((index, match.score, match.positions)) }
        }
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return matches.prefix(limit).map { (headings[$0.index], $0.positions) }
    }
}
