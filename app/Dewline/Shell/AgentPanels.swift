import Foundation
import MdCore

/// A row of What Loads Here or Review: an agent's name over its files, or one file.
struct AgentRow {
    /// Nil for an agent's name.
    let url: URL?
    let title: String
    let detail: String
    /// Dim text after the title: "differs from AGENTS.md".
    let flag: String?
    let tip: String?
}

/// The home folder agents keep their settings, memory and plans under.
let agentHome = FileManager.default.homeDirectoryForCurrentUser.path

/// "differs from AGENTS.md" for each sibling instruction file in `folder` whose sections differ from another's, by path.
func divergenceFlags(in folder: URL) -> [String: (flag: String, sections: [String])] {
    var flags: [String: (String, [String])] = [:]
    for found in siblingDifferences(in: folder.path) {
        flags[found.path] = ("differs from " + URL(filePath: found.other).lastPathComponent, found.sections)
    }
    return flags
}

/// What each agent loads in `folder`: its name with the total, then each file with its estimate against its limit.
func whatLoadsRows(in folder: URL, root: URL?) -> [AgentRow] {
    let flags = divergenceFlags(in: folder)
    let loaded = agentFilesLoaded(in: folder.path, home: agentHome)
    let date = agentLoadLimitsDate()
    var rows: [AgentRow] = []
    for agent in ["Claude Code", "Codex", "Cursor"] {
        let files = loaded.filter { $0.agent == agent }
        guard !files.isEmpty else { continue }
        let total = files.reduce(0) { $0 + $1.tokens }
        rows.append(AgentRow(url: nil, title: agent, detail: "≈\(tokens(total)) tokens", flag: nil, tip: "Estimated at 4 bytes a token; limits as of \(date)"))
        for file in files {
            let url = URL(filePath: file.path)
            let flag = flags[file.path]
            rows.append(AgentRow(
                url: url,
                title: shortPath(url, from: folder, root: root),
                detail: file.limit.map { "\(tokens(file.tokens)) / \(tokens($0))" } ?? tokens(file.tokens),
                flag: flag?.flag,
                tip: ([file.path, file.how] + (flag.map { ["Differs in: " + $0.sections.joined(separator: ", ")] } ?? [])).joined(separator: "\n")
            ))
        }
    }
    return rows
}

private func tokens(_ count: UInt64) -> String {
    count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
}

/// `url` by name in `folder`, relative under `root`, and from the home folder elsewhere.
private func shortPath(_ url: URL, from folder: URL, root: URL?) -> String {
    let path = url.path
    if url.deletingLastPathComponent().path == folder.path { return url.lastPathComponent }
    if let root, path.hasPrefix(root.path + "/") { return String(path.dropFirst(root.path.count + 1)) }
    return (path as NSString).abbreviatingWithTildeInPath
}

/// Agent-written memory and plans changed since they were last opened here, kept in user defaults. Files changed
/// before the review first ran aren't pending.
@MainActor
enum ReviewInbox {
    private static let since = "ReviewSince"
    private static let opened = "ReviewOpened"

    /// The pending files, newest first.
    static func rows(folder: URL?) -> [AgentRow] {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: since) == nil {
            defaults.set(Date.now.timeIntervalSince1970, forKey: since)
        }
        let start = defaults.double(forKey: since)
        let seen = defaults.dictionary(forKey: opened) as? [String: Double] ?? [:]
        return agentReviewFiles(home: agentHome, folder: folder?.path)
            .filter { $0.modified > max(start, seen[$0.path] ?? 0) }
            .prefix(30)
            .map { file in
                let url = URL(filePath: file.path)
                return AgentRow(
                    url: url,
                    title: url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent,
                    detail: shortDate(Date(timeIntervalSince1970: file.modified)),
                    flag: nil,
                    tip: (file.path as NSString).abbreviatingWithTildeInPath
                )
            }
    }

    /// Clears `url` from the review until it changes again.
    static func noteOpened(_ url: URL) {
        var seen = UserDefaults.standard.dictionary(forKey: opened) as? [String: Double] ?? [:]
        seen[url.path] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(seen, forKey: opened)
    }

    /// The folders the review watches: Claude Code's projects and plans, and the folder's `.claude` and `docs/plans`.
    static func roots(folder: URL?) -> [URL] {
        let home = URL(filePath: agentHome)
        let roots = [home.appending(path: ".claude/projects"), home.appending(path: ".claude/plans")]
            + (folder.map { [$0.appending(path: ".claude"), $0.appending(path: "docs/plans")] } ?? [])
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether a change in `changed` can touch the review: a memory folder, not a session's transcripts.
    static func matters(_ changed: URL) -> Bool {
        let path = changed.standardizedFileURL.path
        let projects = URL(filePath: agentHome).appending(path: ".claude/projects").path
        return !path.hasPrefix(projects + "/") || path.hasSuffix("/memory") || path.contains("/memory/")
    }
}
