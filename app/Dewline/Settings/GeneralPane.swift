import AppKit
import SwiftUI

struct GeneralPane: View {
    @Bindable var preferences: Preferences
    let updates: Updates

    var body: some View {
        Form {
            Section {
                Picker("On launch", selection: $preferences.onLaunch) {
                    Text("Reopen last files").tag(Preferences.OnLaunch.lastFiles)
                    Text("Show the launch window").tag(Preferences.OnLaunch.launchWindow)
                }
                Picker("Open documents in", selection: $preferences.opensInSource) {
                    Text("Live").tag(false)
                    Text("Source").tag(true)
                }
            } footer: {
                Text("Live renders Markdown as you write; Source shows the plain text. View > Show Source (⌥⌘U) switches a window.")
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
            Section {
                Toggle("Check for updates automatically", isOn: Binding { updates.automaticChecks } set: { updates.setAutomaticChecks($0) })
                Toggle("Get beta builds", isOn: Binding { updates.beta } set: { updates.setBeta($0) })
                LabeledContent("Last checked") {
                    HStack(spacing: 10) {
                        Text(updates.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                            .foregroundStyle(.secondary)
                        // Sparkle starts no check while it holds a staged update.
                        Button("Check Now") { updates.checkNow() }
                            .disabled(updates.staged != nil)
                    }
                }
                if let error = updates.lastError {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                if let text = updates.stagedText {
                    Text(text)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updates.updater == nil ? "This build does not update itself." : Updates.lineText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(updates.updater == nil)
            RestoreDefaults {
                let factory = Preferences.factory
                preferences.onLaunch = factory.onLaunch
                preferences.opensInSource = factory.opensInSource
                preferences.newFileFolder = factory.newFileFolder
                updates.setAutomaticChecks(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool ?? false)
                updates.setBeta(false)
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
