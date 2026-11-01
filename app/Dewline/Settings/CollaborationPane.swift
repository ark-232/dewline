import SwiftUI

struct CollaborationPane: View {
    @Bindable var preferences: Preferences
    let store: ThemeStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsPage {
            SettingsSection(note: "The person sharing a document sees this name when you ask to join, and everyone in it sees it on your caret.") {
                SettingsRow(label: "Your name") {
                    StationTextField(label: "Your name", text: $preferences.collaborationName)
                        .frame(width: 260)
                }
            }
            SettingsSection(note: "When you join a shared document, your copy is saved here and stays on this Mac after the share ends.") {
                SettingsRow(label: "Shared copies go in") {
                    FolderField(url: preferences.sharedFolder) { preferences.sharedFolder = $0 }
                }
            }
            SettingsSection(title: "Color", note: "A collaborator's edits are marked in this color, under their name.") {
                WriterRow(writer: .collaborator, store: store, dark: scheme == .dark)
            }
            RestoreDefaults {
                let factory = Preferences.factory
                preferences.collaborationName = factory.collaborationName
                preferences.sharedFolder = factory.sharedFolder
                store.writerHues[.collaborator] = nil
            }
        }
    }
}

/// A one-line field as Dewline draws it: Bricolage 13 `ink` on the sunken surface with a hairline edge, and the
/// signal ring while it has focus.
struct StationTextField: View {
    let label: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        TextField(label, text: $text)
            .textFieldStyle(.plain)
            .font(Station.label)
            .foregroundStyle(Station.color(.ink))
            .focused($focused)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(shape.fill(Station.color(.sunken)))
            .overlay(shape.strokeBorder(focused ? Station.color(.signal) : Station.color(.hairline), lineWidth: focused ? 1.5 : 1 / scale))
            .accessibilityLabel(label)
    }
}
