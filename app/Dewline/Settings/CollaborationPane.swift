import SwiftUI

struct CollaborationPane: View {
    @Bindable var preferences: Preferences
    let store: ThemeStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $preferences.collaborationName)
            } footer: {
                Text("The person sharing a document sees this name when you ask to join, and everyone in it sees it on your caret.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Shared copies go in") {
                    FolderField(url: preferences.sharedFolder) { preferences.sharedFolder = $0 }
                }
            } footer: {
                Text("When you join a shared document, your copy is saved here and stays on this Mac after the share ends.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                WriterRow(writer: .collaborator, store: store, dark: scheme == .dark)
            } footer: {
                Text("A collaborator's edits are marked in this color, under their name.")
                    .frame(maxWidth: .infinity, alignment: .leading)
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
