import AppKit
import MdCore

/// A file an agent loads, found in a folder window: its size, and the load limit its agent documents.
struct AgentFile: Equatable, Sendable {
    let url: URL
    let bytes: Int
    let lines: Int
    /// UTF-16 units, as Claude Code counts a file's characters.
    let characters: Int
    let limit: AgentLimit?

    init(url: URL, contents: Data, limit: AgentLimit?) {
        self.url = url
        bytes = contents.count
        let newlines = contents.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        lines = newlines + (contents.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
        characters = String(decoding: contents, as: UTF8.self).utf16.count
        self.limit = limit
    }

    /// About four bytes to a token, counted here; no vendor is asked.
    var estimatedTokens: Int { (bytes + 3) / 4 }

    /// The largest of the file's line, byte and character shares of its limit; past 1 the agent cuts it or warns.
    /// Nil without a limit.
    var load: Double? {
        guard let limit else { return nil }
        return [
            limit.lines.map { Double(lines) / Double($0) },
            limit.bytes.map { Double(bytes) / Double($0) },
            limit.warnCharacters.map { Double(characters) / Double($0) },
        ].compactMap { $0 }.max()
    }

    /// "≈840 tok", "≈3.1k tok", "≈120k tok".
    var tokenLabel: String {
        let tokens = estimatedTokens
        if tokens < 1000 { return "≈\(tokens) tok" }
        if tokens < 100_000 { return "≈" + (Double(tokens) / 1000).formatted(.number.precision(.fractionLength(1))) + "k tok" }
        return "≈\(tokens / 1000)k tok"
    }

    /// The gauge in words: the counts against the limit, per the docs of `date`, and the token estimate.
    func gaugeText(date: String) -> String {
        let estimate = "About \(estimatedTokens.formatted()) tokens, estimated here at four bytes a token."
        guard let limit else { return estimate }
        let counts = [
            limit.lines.map { "\(lines.formatted()) of \($0.formatted()) lines" },
            limit.bytes.map { "\(bytes.formatted()) of \($0.formatted()) bytes" },
        ].compactMap { $0 }.joined(separator: " and ")
        let warning = limit.warnCharacters.map {
            " \(limit.agent) warns past \($0.formatted()) characters; this file has \(characters.formatted())."
        } ?? ""
        return "\(counts) that \(limit.agent) loads, per its docs as of \(date).\(warning) \(estimate)"
    }

    /// The agent files under `root`, sorted by path. The walk skips .git and node_modules, follows no symbolic
    /// link to a folder, goes `depth` folders down and stops after `visits` entries, so a large tree costs a
    /// bounded amount. Only matching files are read.
    static func find(in root: URL, depth: Int = 8, visits: Int = 20_000) -> [AgentFile] {
        let root = root.standardizedFileURL
        var found: [AgentFile] = []
        var queue = [(root, 0)]
        var next = 0
        var visited = 0
        while next < queue.count, visited < visits {
            let (folder, level) = queue[next]
            next += 1
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children where visited < visits {
                visited += 1
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if level + 1 < depth, ![".git", "node_modules"].contains(child.lastPathComponent) {
                        queue.append((child, level + 1))
                    }
                } else if isAgentFile(child), let contents = try? Data(contentsOf: child, options: .mappedIfSafe) {
                    found.append(AgentFile(url: child.standardizedFileURL, contents: contents, limit: agentLimit(for: child)))
                }
            }
        }
        return found.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Whether a change to `folders` can add, remove or resize one of `known`: a folder holds one of them or the
    /// folders above it, or holds an agent file now. A folder of transcripts or build output changes nothing.
    static func mayChange(_ known: [AgentFile], in folders: [URL]) -> Bool {
        var holders = Set<String>()
        for file in known {
            var folder = file.url.deletingLastPathComponent()
            while folder.path != "/", holders.insert(folder.path).inserted {
                folder = folder.deletingLastPathComponent()
            }
        }
        return folders.contains { folder in
            let folder = folder.standardizedFileURL
            if holders.contains(folder.path) { return true }
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return children.contains(where: isAgentFile)
        }
    }
}

/// The front matter's top-level fields on one line, "name: reviewer · description: Reviews diffs", or nil when
/// `text` opens with none. Read as text, never re-serialized.
func frontMatterLine(of text: String) -> String? {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    guard lines.first == "---" else { return nil }
    lines.removeFirst()
    guard let end = lines.firstIndex(where: { $0 == "---" || $0 == "..." }) else { return nil }
    let fields = lines[..<end].compactMap { line -> String? in
        guard let first = line.first, !" \t-#".contains(first), let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "|" || value == ">" ? key : "\(key): \(value)"
    }
    return fields.isEmpty ? nil : fields.joined(separator: " · ")
}

/// A page for a file with front matter: its fields on one read-only line above the editor.
@MainActor
func frontMatterPage(_ line: String, above scrollView: NSScrollView) -> NSView {
    let page = PaperView()
    let label = NSTextField(labelWithString: line)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.isSelectable = true
    label.toolTip = line
    label.setAccessibilityLabel("Front matter, read-only: " + line)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let rule = NSBox()
    rule.boxType = .separator
    for view in [label, rule, scrollView] {
        view.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(view)
    }
    NSLayoutConstraint.activate([
        label.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
        label.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 16),
        label.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -16),
        rule.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
        rule.leadingAnchor.constraint(equalTo: page.leadingAnchor),
        rule.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        scrollView.topAnchor.constraint(equalTo: rule.bottomAnchor),
        scrollView.leadingAnchor.constraint(equalTo: page.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: page.bottomAnchor),
    ])
    return page
}
