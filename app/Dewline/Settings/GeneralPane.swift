import AppKit
import SwiftUI

struct GeneralPane: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("On launch", selection: $preferences.onLaunch) {
                    Text("Reopen last files").tag(Preferences.OnLaunch.lastFiles)
                    Text("Show the launch window").tag(Preferences.OnLaunch.launchWindow)
                }
            } footer: {
                Text("Folder windows open from the launch window or File > Open Folder.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("New files go in") {
                    FolderField(url: preferences.newFileFolder) { preferences.newFileFolder = $0 }
                }
            } footer: {
                Text("The first save of a new document starts here.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A path with a Choose… button that asks for a folder.
struct FolderField: View {
    let url: URL
    let chose: (URL) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(abbreviatedPath(url))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(url.path)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.directoryURL = url
                if panel.runModal() == .OK, let chosen = panel.url { chose(chosen) }
            }
        }
    }
}
