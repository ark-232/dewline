import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilesPane: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsPage {
            SettingsSection(note: "They show dimmed in the sidebar. .git, node_modules and dotfiles stay hidden.") {
                SettingsRow(label: "Show files .gitignore hides") {
                    OnOff(label: "Show files .gitignore hides", isOn: $preferences.showsIgnored)
                }
            }
            SettingsSection {
                SettingsRow(label: "Pasted images go") {
                    TextChoice(label: "Pasted images go", selection: $preferences.attachments, options: [
                        ("Beside the document", .beside), ("In an \u{201C}attachments\u{201D} folder beside it", .subfolder),
                    ])
                }
            }
            SettingsSection(note: "dewline capture adds each entry to the end of this file.") {
                SettingsRow(label: "Inbox") {
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
            }
        }
    }
}
