import Foundation

/// The optional daily note, off by default: Daily/2026-11-02.md in the notes folder, opened from File > Today's Note,
/// the Dock menu, or on the first launch of a day when Settings > Files > Daily note says so.
@MainActor
enum DailyNote {
    /// "off" or "firstLaunch", set by Settings > Files > Daily note.
    static let key = "DewlineDailyNote"
    /// The day the daily note last opened, as yyyy-MM-dd.
    static let openedKey = "DewlineDailyNoteOpened"

    static func isOn(defaults: UserDefaults) -> Bool {
        defaults.string(forKey: key) == "firstLaunch"
    }

    /// "2026-11-02.md", the day in the Mac's time zone.
    static func name(of date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date) + ".md"
    }

    /// Today's note in `root`'s Daily folder, made empty if it isn't there yet.
    static func today(in root: URL, now: Date = Date()) throws -> URL {
        let folder = root.appending(path: "Daily", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name(of: now))
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .withoutOverwriting)
        }
        return url
    }

    /// Whether this launch is the day's first with the daily note on.
    static func opensAtLaunch(defaults: UserDefaults, now: Date = Date()) -> Bool {
        isOn(defaults: defaults) && defaults.string(forKey: openedKey) != name(of: now)
    }

    static func noteOpened(defaults: UserDefaults, now: Date = Date()) {
        defaults.set(name(of: now), forKey: openedKey)
    }
}
