import Foundation
import Testing
@testable import Dewline

/// Every test keeps its settings in a throwaway defaults suite and its files in a temporary folder.
@MainActor
struct SettingsPaneTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "dev.arkwerx.dewline.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func preferencesStartFromTheirDefaults() {
        withDefaults { defaults in
            let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
            let preferences = Preferences(defaults: defaults, home: home)
            #expect(preferences.onLaunch == .lastFiles)
            #expect(preferences.newFileFolder.path == "/Users/someone/Documents")
            #expect(!preferences.showsIgnored)
            #expect(preferences.attachments == .beside)
            #expect(preferences.inbox.path == "/Users/someone/Documents/Dewline/Inbox.md")
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("Dewline") }.isEmpty, "reading writes nothing")
        }
    }

    @Test func preferencesKeepWhatIsSetUnderTheirKeys() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.onLaunch = .launchWindow
            preferences.newFileFolder = URL(filePath: "/tmp/notes", directoryHint: .isDirectory)
            preferences.showsIgnored = true
            preferences.attachments = .subfolder
            preferences.inbox = URL(filePath: "/tmp/notes/Inbox.md")
            #expect(defaults.string(forKey: "DewlineOnLaunch") == "launchWindow")
            #expect(defaults.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool == false)
            #expect(defaults.string(forKey: "DewlineNewFileFolder") == "/tmp/notes")
            #expect(defaults.bool(forKey: "DewlineShowIgnored"))
            #expect(defaults.string(forKey: "DewlineAttachments") == "subfolder")
            #expect(defaults.string(forKey: Preferences.inboxKey) == "/tmp/notes/Inbox.md")

            let reread = Preferences(defaults: defaults)
            #expect(reread.onLaunch == .launchWindow)
            #expect(reread.newFileFolder.path == "/tmp/notes")
            #expect(reread.showsIgnored)
            #expect(reread.attachments == .subfolder)
            #expect(reread.inbox.path == "/tmp/notes/Inbox.md")

            reread.onLaunch = .lastFiles
            #expect(defaults.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool == true)
        }
    }

    @Test func preferencesRefuseValuesTheyCannotUse() {
        withDefaults { defaults in
            defaults.set("sometimes", forKey: "DewlineOnLaunch")
            defaults.set("relative/folder", forKey: "DewlineNewFileFolder")
            defaults.set("cloud", forKey: "DewlineAttachments")
            let preferences = Preferences(defaults: defaults, home: URL(filePath: "/Users/someone", directoryHint: .isDirectory))
            #expect(preferences.onLaunch == .lastFiles)
            #expect(preferences.newFileFolder.path == "/Users/someone/Documents")
            #expect(preferences.attachments == .beside)
        }
    }

    @Test func hookStatusReadsEachAgentsSettings() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HookStatus.read(home: home) == HookStatus(claude: false, codex: false))

        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try Data(#"{"hooks": {"PostToolUse": [{"hooks": [{"type": "command", "command": "dewline notify"}]}]}}"#.utf8)
            .write(to: home.appending(path: ".claude/settings.json"))
        #expect(HookStatus.read(home: home) == HookStatus(claude: true, codex: false))

        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try Data("model = \"gpt\"\n".utf8).write(to: home.appending(path: ".codex/config.toml"))
        #expect(HookStatus.read(home: home).codex == false)
        try Data(#"{"hooks": {"PreToolUse": [{"command": "dewline notify --codex"}]}}"#.utf8).write(to: home.appending(path: ".codex/hooks.json"))
        #expect(HookStatus.read(home: home) == HookStatus(claude: true, codex: true))
    }

    @Test func installCommandRunsTheBundledToolQuoted() {
        #expect(HookStatus.installCommand(bundle: URL(filePath: "/Applications/Dewline.app"))
            == "'/Applications/Dewline.app/Contents/Helpers/dewline' doctor --install-hooks")
        #expect(HookStatus.installCommand(bundle: URL(filePath: "/Users/someone/Rick's Apps/Dewline.app"))
            == #"'/Users/someone/Rick'\''s Apps/Dewline.app/Contents/Helpers/dewline' doctor --install-hooks"#)
    }
}
