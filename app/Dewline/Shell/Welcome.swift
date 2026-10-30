import Foundation

/// Welcome.md: the bundled guide, opened from a copy in ~/Documents/Dewline that the reader owns.
enum Welcome {
    /// True once the guide has opened on a first launch.
    static let shownKey = "DewlineWelcomeShown"
    static let demoLabel = "> [!note] Demo"

    static var bundled: URL {
        Bundle.main.url(forResource: "Welcome", withExtension: "md")!
    }

    static var folder: URL {
        URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: "Documents/Dewline", directoryHint: .isDirectory)
    }

    /// The reader's copy in `folder`, made from `source` when there is none; an existing copy keeps its edits.
    static func copy(from source: URL = bundled, into folder: URL = folder) throws -> URL {
        let copy = folder.appending(path: "Welcome.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.copyItem(at: source, to: copy)
        }
        return copy
    }

    /// Writes a Demo note into the file at `url` from outside the editor, the way an agent writes, replacing the
    /// note an earlier demo left. The watch on the open file sees an outside write like any other.
    static func writeDemo(to url: URL, at date: Date = .now) throws {
        var text = try String(contentsOf: url, encoding: .utf8)
        if let start = text.range(of: "\n" + demoLabel) {
            text.removeSubrange(start.lowerBound...)
            text += "\n"
        }
        if !text.hasSuffix("\n") { text += "\n" }
        let time = date.formatted(date: .omitted, time: .shortened)
        text += "\n\(demoLabel)\n> Another app wrote this note into the file at \(time). Edit the file and run the demo again: your text stays, and only this note changes.\n"
        try Data(text.utf8).write(to: url)
    }
}
