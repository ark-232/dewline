import AppKit
import Observation

/// The General and Files settings, kept in user defaults. Posts `didChange` after every change.
@MainActor @Observable
final class Preferences {
    enum LaunchBehavior: String {
        case lastFiles, launchWindow
    }

    enum DailyNote: String {
        case off
        /// Today's note opens on the first launch of each day.
        case firstLaunch
    }

    /// A key with its modifiers, as `NSEvent` reports them.
    struct Shortcut: Equatable {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags

        /// "⌃⌥Space".
        var label: String {
            let marks: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            let key = Self.names[keyCode] ?? Self.character(keyCode)
            return marks.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
        }

        private static let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc"]

        private static func character(_ keyCode: UInt16) -> String {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
            return event?.charactersIgnoringModifiers?.uppercased() ?? "Key \(keyCode)"
        }
    }

    enum Attachments: String {
        /// Pasted images go in the document's own folder.
        case beside
        /// In an "attachments" folder beside the document.
        case subfolder
    }

    static let shared = Preferences(defaults: .standard)
    /// The settings as a fresh install has them, for Restore Defaults.
    static var factory: Preferences { Preferences(defaults: .factory) }
    static let didChange = Notification.Name("DewlinePreferencesDidChange")
    /// The inbox file `dewline capture` appends to, an absolute path in the app's domain (dev.arkwerx.dewline).
    /// Unset means ~/Documents/Dewline/Inbox.md.
    static let inboxKey = "DewlineInboxPath"

    @ObservationIgnored private let defaults: UserDefaults

    var launchBehavior: LaunchBehavior {
        didSet {
            save(launchBehavior.rawValue, "DewlineOnLaunch")
            keepWindows()
        }
    }
    /// Where Save first looks for a new document.
    var newFileFolder: URL { didSet { save(newFileFolder.path, "DewlineNewFileFolder") } }
    /// The sidebar lists what .gitignore hides, dimmed.
    var showsIgnored: Bool { didSet { save(showsIgnored, "DewlineShowIgnored") } }
    var attachments: Attachments { didSet { save(attachments.rawValue, "DewlineAttachments") } }
    var inbox: URL { didSet { save(inbox.path, Self.inboxKey) } }
    /// New windows open in Source mode rather than Live.
    var opensInSource: Bool { didSet { save(opensInSource, "DewlineOpenInSource") } }
    /// The name a shared document's host and guests see.
    var collaborationName: String { didSet { save(collaborationName, "DewlineCollaborationName") } }
    /// Where a guest's copies of shared documents go.
    var sharedFolder: URL { didSet { save(sharedFolder.path, "DewlineSharedFolder") } }
    /// Cards and hover previews for web links, which ask each site for its title and picture.
    var linkPreviews: Bool { didSet { save(linkPreviews, "DewlineLinkPreviews") } }
    var dailyNote: DailyNote { didSet { save(dailyNote.rawValue, "DewlineDailyNote") } }
    /// The key that opens Capture from any app; none until the user sets one.
    var captureShortcut: Shortcut? {
        didSet {
            if let captureShortcut {
                save(["key": Int(captureShortcut.keyCode), "modifiers": Int(captureShortcut.modifiers.rawValue)], "DewlineCaptureShortcut")
            } else {
                defaults.removeObject(forKey: "DewlineCaptureShortcut")
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }

    init(defaults: UserDefaults, home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)) {
        self.defaults = defaults
        let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
        func path(_ key: String) -> URL? {
            defaults.string(forKey: key).flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
        }
        launchBehavior = defaults.string(forKey: "DewlineOnLaunch").flatMap(LaunchBehavior.init) ?? .lastFiles
        newFileFolder = path("DewlineNewFileFolder") ?? documents.appending(path: "Dewline", directoryHint: .isDirectory)
        showsIgnored = defaults.bool(forKey: "DewlineShowIgnored")
        attachments = defaults.string(forKey: "DewlineAttachments").flatMap(Attachments.init) ?? .beside
        inbox = path(Self.inboxKey) ?? documents.appending(path: "Dewline/Inbox.md")
        opensInSource = defaults.bool(forKey: "DewlineOpenInSource")
        collaborationName = defaults.string(forKey: "DewlineCollaborationName").flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
        sharedFolder = path("DewlineSharedFolder") ?? documents.appending(path: "Dewline Shared", directoryHint: .isDirectory)
        linkPreviews = defaults.object(forKey: "DewlineLinkPreviews") as? Bool ?? true
        dailyNote = defaults.string(forKey: "DewlineDailyNote").flatMap(DailyNote.init) ?? .off
        captureShortcut = (defaults.dictionary(forKey: "DewlineCaptureShortcut") as? [String: Int]).flatMap { saved in
            guard let key = saved["key"], let modifiers = saved["modifiers"] else { return nil }
            return Shortcut(keyCode: UInt16(key), modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
        }
    }

    /// AppKit brings back the last windows only while NSQuitAlwaysKeepsWindows holds; the system's
    /// "Close windows when quitting an application" sets it false for every app that doesn't set its own.
    func keepWindows() {
        defaults.set(launchBehavior == .lastFiles, forKey: "NSQuitAlwaysKeepsWindows")
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

extension UserDefaults {
    /// A domain nothing writes, so it reads every setting at its default.
    static var factory: UserDefaults { UserDefaults(suiteName: "dev.arkwerx.dewline.factory")! }
}
