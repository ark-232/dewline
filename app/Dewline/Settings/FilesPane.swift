import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilesPane: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsRow(label: "Show files .gitignore hides", detail: "They show dimmed in the sidebar.") {
                    OnOff(label: "Show files .gitignore hides", isOn: $preferences.showsIgnored)
                }
                SettingsRow(label: "Pasted images go") {
                    TextChoice(label: "Pasted images go", selection: $preferences.attachments, options: [
                        ("Beside the note", .beside), ("In an \u{201C}attachments\u{201D} folder beside it", .subfolder),
                    ])
                }
            }
            SettingsSection(title: "Daily use") {
                SettingsRow(label: "Daily note") {
                    TextChoice(label: "Daily note", selection: $preferences.dailyNote, options: [
                        ("Off", .off), ("Open on the first launch of the day", .firstLaunch),
                    ])
                }
                SettingsRow(label: "Capture shortcut", detail: "Opens Capture from any app.") {
                    ShortcutField(shortcut: $preferences.captureShortcut)
                }
                SettingsRow(label: "Inbox", detail: "Capture adds each entry to the end of this note.") {
                    PathField(url: preferences.inbox) {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [UTType("net.daringfireball.markdown") ?? .plainText]
                        panel.directoryURL = preferences.inbox.deletingLastPathComponent()
                        panel.nameFieldStringValue = preferences.inbox.lastPathComponent
                        panel.prompt = "Use"
                        if panel.runModal() == .OK, let url = panel.url { preferences.inbox = url }
                    }
                }
            }
            RestoreDefaults {
                let factory = Preferences.factory
                preferences.showsIgnored = factory.showsIgnored
                preferences.attachments = factory.attachments
                preferences.inbox = factory.inbox
                preferences.dailyNote = factory.dailyNote
                preferences.captureShortcut = nil
            }
        }
    }
}

/// The key that is set, or "Record Shortcut"; while recording, the next key with a modifier becomes the shortcut and
/// Escape stops without one. Clear removes it.
private struct ShortcutField: View {
    @Binding var shortcut: Preferences.Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Type a Shortcut" : shortcut?.label ?? "Record Shortcut") {
                recording ? stop() : record()
            }
            if shortcut != nil, !recording {
                Button("Clear") { shortcut = nil }
            }
        }
        .onDisappear { stop() }
    }

    private func record() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if event.keyCode == 53, modifiers.isEmpty {
                stop()
                return nil
            }
            guard !modifiers.subtracting(.shift).isEmpty else { return nil }
            shortcut = Preferences.Shortcut(keyCode: event.keyCode, modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
