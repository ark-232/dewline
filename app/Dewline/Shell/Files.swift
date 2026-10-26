import AppKit
import MdCore

/// A folder's top-level .gitignore, in the subset notes need: globs, a trailing slash for folders only,
/// and a leading or inner slash to anchor a pattern at the root. Negations are skipped.
struct GitIgnore {
    private var patterns: [(glob: String, anchored: Bool, foldersOnly: Bool)] = []

    init(_ contents: String) {
        for raw in contents.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            let foldersOnly = line.hasSuffix("/")
            if foldersOnly { line.removeLast() }
            if line.hasPrefix("**/") { line.removeFirst(3) }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            if !line.isEmpty { patterns.append((line, anchored, foldersOnly)) }
        }
    }

    /// Whether `path`, relative to the root and "/"-separated, is ignored.
    func ignores(_ path: String, isFolder: Bool) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return patterns.contains { pattern in
            guard isFolder || !pattern.foldersOnly else { return false }
            return pattern.anchored
                ? fnmatch(pattern.glob, path, FNM_PATHNAME) == 0
                : fnmatch(pattern.glob, name, 0) == 0
        }
    }
}

/// One file or folder in a folder tree.
struct FolderEntry: Equatable {
    let url: URL
    let isFolder: Bool

    var isMarkdown: Bool {
        !isFolder && ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}

/// A folder opened in a window: lists its children the way the sidebar shows them.
struct Folder {
    let url: URL
    let ignore: GitIgnore

    init(_ url: URL) {
        self.url = url.standardizedFileURL
        ignore = GitIgnore((try? String(contentsOf: url.appending(path: ".gitignore"), encoding: .utf8)) ?? "")
    }

    /// The visible children of `folder`, folders first, in Finder order, and the names .gitignore hid.
    /// Dotfiles, .git and node_modules never show.
    func children(of folder: URL) -> (entries: [FolderEntry], ignored: [String]) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        var entries: [FolderEntry] = []
        var ignored: [String] = []
        for child in urls where child.lastPathComponent != "node_modules" {
            let isFolder = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let entry = FolderEntry(url: child.standardizedFileURL, isFolder: isFolder)
            if let path = relativePath(of: entry.url), ignore.ignores(path, isFolder: isFolder) {
                ignored.append(child.lastPathComponent + (isFolder ? "/" : ""))
            } else {
                entries.append(entry)
            }
        }
        entries.sort { a, b in
            a.isFolder != b.isFolder
                ? a.isFolder
                : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        return (entries, ignored.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// The path of `file` under this folder, "/"-separated, or nil when it lies outside.
    func relativePath(of file: URL) -> String? {
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(url.path + "/") else { return nil }
        return String(path.dropFirst(url.path.count + 1))
    }
}

/// Recent files, recent folders and pins, kept in user defaults.
@MainActor
enum Library {
    static let changed = Notification.Name("DewlineLibraryChanged")

    struct Visit: Equatable {
        let url: URL
        let date: Date
    }

    static var recents: [Visit] { visits("RecentFiles") }
    static var recentFolders: [Visit] { visits("RecentFolders") }
    static var pins: [URL] {
        (UserDefaults.standard.stringArray(forKey: "Pins") ?? []).map { URL(filePath: $0, directoryHint: .checkFileSystem) }
    }

    static func noteOpened(_ url: URL, folder: Bool = false) {
        let key = folder ? "RecentFolders" : "RecentFiles"
        store(adding(Visit(url: url, date: .now), to: visits(key), limit: 20), key)
    }

    static func forget(_ url: URL) {
        store(recents.filter { $0.url != url }, "RecentFiles")
    }

    static func setPinned(_ url: URL, _ pinned: Bool) {
        let paths = pins.map(\.path).filter { $0 != url.path } + (pinned ? [url.path] : [])
        UserDefaults.standard.set(paths, forKey: "Pins")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    nonisolated static func adding(_ visit: Visit, to visits: [Visit], limit: Int) -> [Visit] {
        Array(([visit] + visits.filter { $0.url != visit.url }).prefix(limit))
    }

    private static func visits(_ key: String) -> [Visit] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = entry["path"] as? String, let date = entry["date"] as? Date else { return nil }
            return Visit(url: URL(filePath: path), date: date)
        }
    }

    private static func store(_ visits: [Visit], _ key: String) {
        UserDefaults.standard.set(visits.map { ["path": $0.url.path, "date": $0.date] }, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// A heading in the open file's outline.
struct Heading: Equatable {
    let level: Int
    let title: String
    /// UTF-16 offset of the heading's first character.
    let location: Int
    let line: Int
}

/// The H1 to H3 headings of `text`, with their 1-based line numbers.
func outline(of text: String) -> [Heading] {
    let string = text as NSString
    var line = 1
    var counted = 0
    return markdownSpans(in: text).compactMap { span in
        guard case .heading(let level) = span.kind, level <= 3 else { return nil }
        for index in counted..<span.range.location where string.character(at: index) == 0x0A {
            line += 1
        }
        counted = span.range.location
        let title = plainInline(string.substring(with: span.content))
        return title.isEmpty ? nil : Heading(level: level, title: title, location: span.range.location, line: line)
    }
}

/// The first line of prose in a markdown file's opening, past front matter, headings, fences and rules,
/// without list, quote or inline markers. Falls back to the first heading.
func firstProseLine(of text: String) -> String? {
    var heading: String?
    var inFrontMatter = false
    var inFence = false
    for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if index == 0, line == "---" {
            inFrontMatter = true
        } else if inFrontMatter {
            inFrontMatter = line != "---" && line != "..."
        } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
            inFence.toggle()
        } else if inFence || line.isEmpty || line.allSatisfy({ "-*_=".contains($0) }) || line.hasPrefix("<") {
            continue
        } else if line.hasPrefix("#") {
            heading = heading ?? plainInline(String(line.drop { $0 == "#" }))
        } else {
            let body = line.replacingOccurrences(
                of: #"^(?:>\s*)*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)?"#, with: "", options: .regularExpression
            )
            let prose = plainInline(body)
            if !prose.isEmpty { return prose }
        }
    }
    return heading
}

/// `markdown` without link targets, wikilink brackets and emphasis or code markers.
private func plainInline(_ markdown: String) -> String {
    markdown
        .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\[\[([^\]|]*)(?:\|([^\]]*))?\]\]"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\*\*|__|~~|[*`]"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// "9:12 AM" today, "Yesterday", a weekday within the week, then the date.
func shortDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let locale = calendar.locale ?? .current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    switch days {
    case ...0: style = style.hour().minute()
    case 1: return "Yesterday"
    case 2..<7: style = style.weekday(.wide)
    default:
        style = style.day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
    }
    return date.formatted(style)
}

/// The branch a repository at `folder` has checked out, read from .git/HEAD.
func gitBranch(at folder: URL) -> String? {
    guard let head = try? String(contentsOf: folder.appending(path: ".git/HEAD"), encoding: .utf8),
        head.hasPrefix("ref: refs/heads/")
    else { return nil }
    return head.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `url`'s path with the home folder as "~".
func abbreviatedPath(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}
