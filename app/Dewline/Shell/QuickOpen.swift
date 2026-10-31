import AppKit

/// Text prepared once for letter-order matching: its UTF-16 code units folded to lowercase without accents, and a
/// bonus for each unit that starts a word, a path segment or the file name.
struct FuzzyText: Sendable {
    let string: String
    /// UTF-16 offset where the last path segment starts.
    let nameStart: Int
    private let units: [UInt16]
    private let bonus: [Int8]

    private static let base = 16
    private static let consecutive = 8
    private static let gapOpen = 6
    private static let gapExtend = 1

    init(_ string: String) {
        self.string = string
        let original = Array(string.utf16)
        let slash = UInt16(UInt8(ascii: "/"))
        let nameStart = original.lastIndex(of: slash).map { $0 + 1 } ?? 0
        self.nameStart = nameStart
        units = original.map(Self.fold)
        bonus = original.indices.map { index -> Int8 in
            let inName: Int8 = index >= nameStart ? 2 : 0
            guard index > 0 else { return 9 + inName }
            let previous = original[index - 1]
            if previous == slash { return 9 + inName }
            if Self.separators.contains(previous) { return 7 + inName }
            if Self.isLower(previous), Self.isUpper(original[index]) { return 6 + inName }
            return inName
        }
    }

    private static let separators = Set(" -_.(›".utf16)

    private static func isLower(_ unit: UInt16) -> Bool { (97...122).contains(unit) }
    private static func isUpper(_ unit: UInt16) -> Bool { (65...90).contains(unit) }

    /// `unit` in lowercase and without its accent, when that is still one unit.
    static func fold(_ unit: UInt16) -> UInt16 {
        if isUpper(unit) { return unit + 32 }
        guard unit >= 128, let scalar = Unicode.Scalar(unit) else { return unit }
        let folded = String(Character(scalar)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf16
        return folded.count == 1 ? folded.first! : unit
    }

    /// Whether `query`'s letters all appear, in order, in the last path segment.
    func nameHolds(_ query: [UInt16]) -> Bool {
        var found = 0
        for unit in units[nameStart...] where found < query.count && unit == query[found] {
            found += 1
        }
        return found == query.count
    }

    /// `query` as `match` takes it: folded, without spaces.
    static func query(_ query: String) -> [UInt16] {
        query.utf16.filter { $0 != 32 && $0 != 9 }.map(fold)
    }

    /// The best alignment of `query`'s letters, in order, in this text, or nil when they don't all appear. Runs and
    /// letters at word starts score higher and gaps lower; `positions` asks for the UTF-16 offsets of the letters.
    func match(_ query: [UInt16], positions wantsPositions: Bool = false) -> (score: Int, positions: [Int])? {
        let m = query.count
        let n = units.count
        guard m > 0 else { return (0, []) }
        var found = 0
        for unit in units where unit == query[found] {
            found += 1
            if found == m { break }
        }
        guard found == m else { return nil }
        // previous[j] is the best score with the last query letter so far at j.
        let none = Int.min / 4
        var previous = [Int](repeating: none, count: n)
        var current = previous
        var from = wantsPositions ? [Int32](repeating: -1, count: m * n) : []
        for i in 0..<m {
            var gap = none
            var gapFrom = -1
            for j in 0..<n {
                if i > 0, j >= 2, previous[j - 2] - Self.gapOpen > gap - Self.gapExtend {
                    gap = previous[j - 2] - Self.gapOpen
                    gapFrom = j - 2
                } else {
                    gap -= Self.gapExtend
                }
                current[j] = none
                guard units[j] == query[i] else { continue }
                var best = 0
                var source = -1
                if i > 0 {
                    let run = j > 0 ? previous[j - 1] + Self.consecutive : none
                    (best, source) = run >= gap ? (run, j - 1) : (gap, gapFrom)
                    guard best > none / 2 else { continue }
                }
                current[j] = best + Self.base + Int(bonus[j])
                if wantsPositions { from[i * n + j] = Int32(source) }
            }
            swap(&previous, &current)
        }
        guard let end = previous.indices.max(by: { previous[$0] < previous[$1] }), previous[end] > none / 2 else { return nil }
        guard wantsPositions else { return (previous[end], []) }
        var positions = [Int](repeating: 0, count: m)
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = Int(from[i * n + j])
        }
        return (previous[end], positions)
    }
}

/// A Markdown file Quick Open can offer, matched by its path under the open folder, or by its full path outside it.
struct QuickOpenFile: Sendable {
    let url: URL
    let text: FuzzyText
    /// Its place among recents, then pins; nil for other files.
    var boost: Int?

    init(_ url: URL, path: String, boost: Int? = nil) {
        self.url = url
        text = FuzzyText(path)
        self.boost = boost
    }

    /// The file's path the way Quick Open shows it: under `folder` when it lies there, else in full with the home
    /// folder as "~".
    init(_ url: URL, in folder: Folder?, boost: Int? = nil) {
        self.init(url, path: folder?.relativePath(of: url) ?? abbreviatedPath(url), boost: boost)
    }
}

/// A row in Quick Open: a file and the offsets of its matched letters.
struct QuickOpenResult: Sendable {
    let file: QuickOpenFile
    let positions: [Int]
}

enum QuickOpen {
    /// `files` with recents and pins (`boosted`, in that order) marked, and the ones outside `files` added after them.
    /// Files are compared by the path Quick Open shows, which names one file.
    static func merge(_ files: [QuickOpenFile], boosted: [URL], in folder: Folder?) -> [QuickOpenFile] {
        var rank: [String: Int] = [:]
        var extra: [QuickOpenFile] = []
        for (index, url) in boosted.enumerated() {
            let file = QuickOpenFile(url, in: folder, boost: index)
            guard rank[file.text.string] == nil else { continue }
            rank[file.text.string] = index
            extra.append(file)
        }
        var merged = files
        for index in merged.indices {
            if let boost = rank.removeValue(forKey: merged[index].text.string) { merged[index].boost = boost }
        }
        return merged + extra.filter { rank[$0.text.string] != nil }
    }

    /// The files matching `query`: recents and pins first when their names hold its letters or it names a folder
    /// with "/", then by match quality, then shorter paths. With no query, only recents and pins, in that order. Nil
    /// when cancelled.
    static func rank(_ query: String, in files: [QuickOpenFile], limit: Int = 200) -> [QuickOpenResult]? {
        let letters = FuzzyText.query(query)
        guard !letters.isEmpty else {
            let boosted = files.compactMap { file in file.boost.map { ($0, file) } }.sorted { $0.0 < $1.0 }
            return boosted.prefix(limit).map { QuickOpenResult(file: $0.1, positions: []) }
        }
        let slash = query.contains("/")
        var matches: [(index: Int, score: Int, boost: Int?)] = []
        for (index, file) in files.enumerated() {
            if index % 2048 == 0, Task.isCancelled { return nil }
            if let match = file.text.match(letters) {
                matches.append((index, match.score, file.boost.flatMap { slash || file.text.nameHolds(letters) ? $0 : nil }))
            }
        }
        matches.sort { a, b in
            let (x, y) = (files[a.index], files[b.index])
            if (a.boost == nil) != (b.boost == nil) { return a.boost != nil }
            if a.score != b.score { return a.score > b.score }
            if let p = a.boost, let q = b.boost { return p < q }
            if x.text.string.utf16.count != y.text.string.utf16.count { return x.text.string.utf16.count < y.text.string.utf16.count }
            return x.text.string < y.text.string
        }
        return matches.prefix(limit).map { match in
            let file = files[match.index]
            return QuickOpenResult(file: file, positions: file.text.match(letters, positions: true)?.positions ?? [])
        }
    }
}

/// The Markdown files under a folder by the folder that holds them, listed the way the sidebar lists them.
struct FileTree: Sendable {
    let folder: Folder
    private var listings: [String: (files: [QuickOpenFile], folders: [String])] = [:]

    init(_ folder: Folder) {
        self.folder = folder
    }

    /// Every file in the sidebar's order: each folder's subfolders with what they hold, then its own files.
    var files: [QuickOpenFile] {
        var files: [QuickOpenFile] = []
        func add(_ path: String) {
            guard let listing = listings[path] else { return }
            for folder in listing.folders {
                add(folder)
            }
            files += listing.files
        }
        add(folder.url.path)
        return files
    }

    /// Lists `paths` again, scanning folders that appeared and forgetting those that went; nil lists the whole tree.
    /// Paths the tree doesn't hold, such as hidden or ignored folders, are skipped.
    mutating func relist(_ paths: [String]?) {
        guard let paths else {
            listings = [:]
            scan(folder.url.path)
            return
        }
        for path in paths {
            guard let old = listings[path]?.folders else { continue }
            let listing = list(path)
            listings[path] = listing
            for gone in Set(old).subtracting(listing.folders) {
                forget(gone)
            }
            for added in Set(listing.folders).subtracting(old) {
                scan(added)
            }
        }
    }

    private mutating func scan(_ path: String) {
        let listing = list(path)
        listings[path] = listing
        for child in listing.folders {
            scan(child)
        }
    }

    private mutating func forget(_ path: String) {
        for child in listings.removeValue(forKey: path)?.folders ?? [] {
            forget(child)
        }
    }

    private func list(_ path: String) -> (files: [QuickOpenFile], folders: [String]) {
        let entries = folder.children(of: URL(filePath: path, directoryHint: .isDirectory)).entries
        return (
            entries.filter(\.isMarkdown).map { QuickOpenFile($0.url, in: folder) },
            entries.filter(\.isFolder).map(\.url.path)
        )
    }
}

/// An open folder's Markdown files, kept in memory and current through FSEvents so Quick Open never waits on the
/// disk. The folder's tabs share one; it lives while one of them holds it.
@MainActor
final class FolderIndex {
    static let changed = Notification.Name("DewlineFolderIndexChanged")
    private static let open = NSMapTable<NSString, FolderIndex>.strongToWeakObjects()

    static func of(_ folder: Folder) -> FolderIndex {
        if let index = open.object(forKey: folder.url.path as NSString) { return index }
        let index = FolderIndex(folder)
        open.setObject(index, forKey: folder.url.path as NSString)
        return index
    }

    /// Every Markdown file, or nil until the first listing finishes.
    private(set) var files: [QuickOpenFile]?
    private var tree: FileTree
    private var watch: FolderWatch?
    private var update: Task<Void, Never>?

    private init(_ folder: Folder) {
        tree = FileTree(folder)
        watch = FolderWatch([folder.url]) { [weak self] folders in
            self?.relist(folders.map(\.standardizedFileURL.path))
        }
        relist(nil)
    }

    /// Lists again off the main thread, one update after another.
    private func relist(_ paths: [String]?) {
        update = Task { [previous = update, weak self] in
            await previous?.value
            guard let tree = self?.tree else { return }
            let listed = await Task.detached(priority: .utility) {
                var tree = tree
                tree.relist(paths)
                return (tree, tree.files)
            }.value
            guard let self else { return }
            self.tree = listed.0
            files = listed.1
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
}

/// A menu item the command palette offers, with the menus above it and its key equivalent as glyphs.
@MainActor
struct MenuCommand {
    let item: NSMenuItem
    /// The titles of the menus above the item, such as "View" or "Format › Font".
    let path: String
    let title: FuzzyText
    /// The path and other words for the command, matched when the title is not.
    let synonyms: FuzzyText

    /// Words people type for commands whose titles say it differently, by action.
    private static let words: [String: String] = [
        "showSettings:": "Preferences Options",
        "toggleSource:": "Markdown Raw Syntax",
        "goToLine:": "Jump",
        "performFindPanelAction:": "Search",
        "openFolder:": "Directory Project",
        "quickOpen:": "Go to File",
        "toggleSidebar:": "Files Tree",
    ]

    /// Every enabled item in `menu` and its submenus, in menu order, after the menus validate their items against the
    /// key window as the menu bar does when it opens. Separators, hidden items, section headers and `excluding` are left
    /// out.
    static func all(in menu: NSMenu, path: [String] = [], excluding: Selector? = nil) -> [MenuCommand] {
        menu.update()
        return menu.items.flatMap { item -> [MenuCommand] in
            if item.isSeparatorItem || item.isHidden || item.isSectionHeader { return [] }
            if let submenu = item.submenu {
                return all(in: submenu, path: path + [submenu.title.isEmpty ? item.title : submenu.title], excluding: excluding)
            }
            guard item.isEnabled, let action = item.action, action != excluding, !item.title.isEmpty else { return [] }
            let menus = path.joined(separator: " › ")
            let synonyms = [menus, words[NSStringFromSelector(action)] ?? ""].joined(separator: " ")
            return [MenuCommand(item: item, path: menus, title: FuzzyText(item.title), synonyms: FuzzyText(synonyms))]
        }
    }

    /// Commands matching `query`, by title before synonyms, then by match quality, then in menu order; all of them for
    /// an empty query. Each comes with the offsets of its title's matched letters.
    static func rank(_ query: String, in commands: [MenuCommand]) -> [(command: MenuCommand, positions: [Int])] {
        let letters = FuzzyText.query(query)
        guard !letters.isEmpty else { return commands.map { ($0, []) } }
        let scored = commands.enumerated().compactMap { index, command -> (Int, Int, MenuCommand, [Int])? in
            if let match = command.title.match(letters, positions: true) { return (match.score, index, command, match.positions) }
            if let match = command.synonyms.match(letters) { return (match.score - 1000, index, command, []) }
            return nil
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map { ($0.2, $0.3) }
    }

    var shortcut: String {
        KeyEquivalent(item.keyEquivalent, item.keyEquivalentModifierMask).glyphs
    }

    /// Sends the item's action as a click in its menu does.
    func perform() {
        guard let menu = item.menu else { return }
        menu.performActionForItem(at: menu.index(of: item))
    }
}

/// A menu item's key equivalent, written as the menu bar draws it (⌥⌘U) and as VoiceOver should say it.
struct KeyEquivalent {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    /// An uppercase letter stands for Shift and the letter, as in a menu item's key equivalent.
    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        var modifiers = modifiers.intersection([.control, .option, .shift, .command])
        if key.lowercased() != key { modifiers.insert(.shift) }
        self.key = key
        self.modifiers = modifiers
    }

    private static let order: [(NSEvent.ModifierFlags, glyph: String, name: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
    ]

    private static let keys: [Int: (glyph: String, name: String)] = [
        0x0D: ("↩", "Return"), 0x03: ("⌤", "Enter"), 0x09: ("⇥", "Tab"), 0x1B: ("⎋", "Escape"), 0x20: ("Space", "Space"),
        0x08: ("⌫", "Delete"), 0x7F: ("⌫", "Delete"), NSDeleteFunctionKey: ("⌦", "Forward Delete"),
        NSUpArrowFunctionKey: ("↑", "Up Arrow"), NSDownArrowFunctionKey: ("↓", "Down Arrow"),
        NSLeftArrowFunctionKey: ("←", "Left Arrow"), NSRightArrowFunctionKey: ("→", "Right Arrow"),
        NSHomeFunctionKey: ("↖", "Home"), NSEndFunctionKey: ("↘", "End"),
        NSPageUpFunctionKey: ("⇞", "Page Up"), NSPageDownFunctionKey: ("⇟", "Page Down"),
    ]

    private var keyName: (glyph: String, name: String) {
        guard let scalar = key.unicodeScalars.first else { return ("", "") }
        let code = Int(scalar.value)
        if let named = Self.keys[code] { return named }
        if (NSF1FunctionKey...NSF35FunctionKey).contains(code) {
            let name = "F\(code - NSF1FunctionKey + 1)"
            return (name, name)
        }
        return (key.uppercased(), key.uppercased())
    }

    var glyphs: String {
        guard !key.isEmpty else { return "" }
        return Self.order.filter { modifiers.contains($0.0) }.map(\.glyph).joined() + keyName.glyph
    }

    var spoken: String {
        guard !key.isEmpty else { return "" }
        return (Self.order.filter { modifiers.contains($0.0) }.map(\.name) + [keyName.name]).joined(separator: " ")
    }
}
