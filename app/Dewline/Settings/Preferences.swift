import Foundation
import Observation

/// The General and Files settings, kept in user defaults. Posts `didChange` after every change.
@MainActor @Observable
final class Preferences {
    enum OnLaunch: String {
        case lastFiles, launchWindow
    }

    enum Attachments: String {
        /// Pasted images go in the document's own folder.
        case beside
        /// In an "attachments" folder beside the document.
        case subfolder
    }

    static let shared = Preferences(defaults: .standard)
    static let didChange = Notification.Name("DewlinePreferencesDidChange")
    /// The inbox file `dewline capture` appends to, an absolute path in the app's domain (dev.arkwerx.dewline).
    /// Unset means ~/Documents/Dewline/Inbox.md.
    static let inboxKey = "DewlineInboxPath"

    @ObservationIgnored private let defaults: UserDefaults

    var onLaunch: OnLaunch {
        didSet {
            save(onLaunch.rawValue, "DewlineOnLaunch")
            keepWindows()
        }
    }
    /// Where Save first looks for a new document.
    var newFileFolder: URL { didSet { save(newFileFolder.path, "DewlineNewFileFolder") } }
    /// The sidebar lists what .gitignore hides, dimmed.
    var showsIgnored: Bool { didSet { save(showsIgnored, "DewlineShowIgnored") } }
    var attachments: Attachments { didSet { save(attachments.rawValue, "DewlineAttachments") } }
    var inbox: URL { didSet { save(inbox.path, Self.inboxKey) } }

    init(defaults: UserDefaults, home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)) {
        self.defaults = defaults
        let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
        func path(_ key: String) -> URL? {
            defaults.string(forKey: key).flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
        }
        onLaunch = defaults.string(forKey: "DewlineOnLaunch").flatMap(OnLaunch.init) ?? .lastFiles
        newFileFolder = path("DewlineNewFileFolder") ?? documents
        showsIgnored = defaults.bool(forKey: "DewlineShowIgnored")
        attachments = defaults.string(forKey: "DewlineAttachments").flatMap(Attachments.init) ?? .beside
        inbox = path(Self.inboxKey) ?? documents.appending(path: "Dewline/Inbox.md")
    }

    /// AppKit brings back the last windows only while NSQuitAlwaysKeepsWindows holds; the system's
    /// "Close windows when quitting an application" sets it false for every app that doesn't set its own.
    func keepWindows() {
        defaults.set(onLaunch == .lastFiles, forKey: "NSQuitAlwaysKeepsWindows")
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
