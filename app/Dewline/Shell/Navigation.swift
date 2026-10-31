import Foundation

/// Where a reader was in a file: the caret, and the character at the top of the page with the page's offset from
/// that character's baseline, so the page comes back to the same pixel after the text lays out again.
struct Place: Codable, Equatable {
    var caret: Int
    var top: Int
    var offset: Double
}

/// A tab's back and forward stack. Opening a file pushes; scrolling does not.
struct History {
    struct Entry: Equatable {
        let url: URL
        /// Recorded when the entry is left, so a fresh entry has none.
        var place: Place? = nil
    }

    static let limit = 100

    private(set) var entries: [Entry] = []
    private(set) var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }

    /// Pushes `url`, dropping anything forward of the current entry, which keeps `place` as where it was left.
    mutating func visit(_ url: URL, leaving place: Place?) {
        if entries.indices.contains(index) { entries[index].place = place ?? entries[index].place }
        entries.removeSubrange((index + 1)...)
        entries.append(Entry(url: url))
        entries.removeFirst(max(0, entries.count - Self.limit))
        index = entries.count - 1
    }

    mutating func back(leaving place: Place?) -> Entry? { step(-1, leaving: place) }
    mutating func forward(leaving place: Place?) -> Entry? { step(1, leaving: place) }

    private mutating func step(_ delta: Int, leaving place: Place?) -> Entry? {
        guard entries.indices.contains(index + delta) else { return nil }
        entries[index].place = place ?? entries[index].place
        index += delta
        return entries[index]
    }
}

/// The windows open at quit, back to front, so reopening them in order leaves the last one in front.
struct Session: Codable, Equatable {
    struct Tab: Codable, Equatable {
        let path: String
        let place: Place
    }

    struct Window: Codable, Equatable {
        let folder: String?
        let tabs: [Tab]
        /// The tab that was selected, an index into `tabs`.
        let selected: Int
    }

    static let key = "DewlineSession"

    var windows: [Window]

    static func load(from defaults: UserDefaults) -> Session? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// The folders from `root` down to `file`, then the file. A file outside `root` shows under its own folder.
func breadcrumbs(of file: URL?, in root: URL?) -> [URL] {
    let root = root?.standardizedFileURL
    guard let file = file?.standardizedFileURL else { return root.map { [$0] } ?? [] }
    guard let root, file.path.hasPrefix(root.path + "/") else { return [file.deletingLastPathComponent(), file] }
    var folders = [root]
    for name in file.deletingLastPathComponent().path.dropFirst(root.path.count).split(separator: "/") {
        folders.append(folders.last!.appending(path: String(name), directoryHint: .isDirectory))
    }
    return folders + [file]
}
