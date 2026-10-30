import AppKit
import Testing
@testable import Dewline

/// The menu bar is the one table of Dewline's shortcuts: these tests check it and write docs/keyboard.md from it.
@MainActor
struct MainMenuTests {
    /// Shortcuts macOS and AppKit keep for themselves, from Apple's "Mac keyboard shortcuts"
    /// (https://support.apple.com/en-us/102650, published 14 September 2026), and ⌘F5, which turns VoiceOver on and off
    /// (https://support.apple.com/guide/voiceover/general-commands-cpvokys01/mac). The page's other app shortcuts (⌘C,
    /// ⌘Q, Help's ⇧⌘?…) belong to the standard items that use them, so they are not here.
    private static let reserved: Set<String> = [
        "⌘Space", "⌥⌘Space", "⇧⌘Space", "⌃⌘Space", "⌃Space",  // Spotlight, Siri, Character Viewer, input sources
        "⌘⇥", "⌘`", "⇧⌘`", "⌥⌘`", "⌃⇥", "⌃⇧⇥",  // switching apps, windows and controls
        "⇧⌘3", "⇧⌘4", "⇧⌘5", "⇧⌘6",  // screenshots, Siri
        "⌥⌘⎋", "⌃⌘Q", "⇧⌘Q", "⌥⇧⌘Q",  // Force Quit, lock, log out
        "⌃⌘F", "⌥⌘W", "⌥⌘M",  // full screen, close all windows, minimize all windows
        "⌃⌘D", "⌥⌘D", "F11",  // Look Up, the Dock, the desktop
        "⌃↑", "⌃↓", "⌃←", "⌃→",  // Mission Control, keyboard focus
        "⌃F2", "⌃F3", "⌃F4", "⌃F5", "⌃F6", "⌃⇧F6", "⌃F7", "⌃F8",  // keyboard focus
        "⌘F5", "⌥⌘F5",  // VoiceOver, Accessibility Shortcuts
    ]

    /// The items with a shortcut in the menu bar MainMenu builds, in menu order. AppKit's own additions, such as
    /// Emoji & Symbols, are not in it.
    private func shortcuts() -> [(path: String, title: String, key: KeyEquivalent)] {
        var found: [(path: String, title: String, key: KeyEquivalent)] = []
        func walk(_ menu: NSMenu, _ menus: [String]) {
            for item in menu.items {
                if let submenu = item.submenu {
                    walk(submenu, menus + [submenu.title])
                } else if !item.keyEquivalent.isEmpty {
                    let key = KeyEquivalent(item.keyEquivalent, item.keyEquivalentModifierMask)
                    found.append((menus.joined(separator: " › "), item.title, key))
                }
            }
        }
        // MainMenu.build() hands its Window menu to the app; the app keeps the one in its menu bar.
        let windows = NSApp.windowsMenu
        walk(MainMenu.build(), [])
        NSApp.windowsMenu = windows
        return found
    }

    @Test func shortcutsAreUniqueAndClearOfMacOSAndVoiceOver() {
        let all = shortcuts()
        for (glyphs, items) in Dictionary(grouping: all, by: \.key.glyphs) {
            #expect(items.count == 1, "\(glyphs) is on \(items.map { "\($0.path) › \($0.title)" })")
        }
        for shortcut in all {
            let item = "\(shortcut.path) › \(shortcut.title)"
            #expect(!Self.reserved.contains(shortcut.key.glyphs), "\(item) takes \(shortcut.key.glyphs) from macOS")
            // VoiceOver's VO key is ⌃⌥, so every ⌃⌥ shortcut is a VoiceOver command.
            #expect(!shortcut.key.modifiers.isSuperset(of: [.control, .option]), "\(item) takes \(shortcut.key.glyphs) from VoiceOver")
        }
    }

    /// DEWLINE_KEYBOARD_DOC (TEST_RUNNER_DEWLINE_KEYBOARD_DOC through xcodebuild) writes the file before comparing.
    @Test func keyboardDocListsTheMenuBar() throws {
        let rows = shortcuts().map { "| \($0.title) | \($0.path) | \($0.key.glyphs) |" }
        let text = ([
            "# Keyboard shortcuts", "",
            "The shortcuts `app/Dewline/MainMenu.swift` puts in the menu bar, written here by `MainMenuTests`.", "",
            "| Command | Menu | Shortcut |", "| --- | --- | --- |",
        ] + rows).joined(separator: "\n") + "\n"
        let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "docs/keyboard.md")
        if ProcessInfo.processInfo.environment["DEWLINE_KEYBOARD_DOC"] != nil {
            try text.write(to: doc, atomically: true, encoding: .utf8)
        }
        #expect((try? String(contentsOf: doc, encoding: .utf8)) == text, """
            docs/keyboard.md differs from the menu bar. Rewrite it with
            TEST_RUNNER_DEWLINE_KEYBOARD_DOC=1 xcodebuild test -project app/Dewline.xcodeproj -scheme Dewline \
            -destination 'platform=macOS' -only-testing:DewlineTests/MainMenuTests CODE_SIGNING_ALLOWED=NO
            """)
    }
}
