import SwiftUI

struct CollaborationPane: View {
    @Bindable var preferences: Preferences
    let store: ThemeStore

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsRow(label: "Your name", detail: "People you share with see it on your caret.") {
                    StationTextField(label: "Your name", text: $preferences.collaborationName)
                        .frame(width: 260)
                }
                SettingsRow(label: "Shared notes go in", detail: "Your copy stays here after sharing ends.") {
                    FolderField(url: preferences.sharedFolder) { preferences.sharedFolder = $0 }
                }
            }
            RestoreDefaults {
                let factory = Preferences.factory
                preferences.collaborationName = factory.collaborationName
                preferences.sharedFolder = factory.sharedFolder
            }
        }
    }
}

/// A standard one-line text field.
struct StationTextField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .accessibilityLabel(label)
    }
}
