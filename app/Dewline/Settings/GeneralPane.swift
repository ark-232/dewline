import AppKit
import SwiftUI

struct GeneralPane: View {
    @Bindable var preferences: Preferences
    let updates: Updates

    var body: some View {
        SettingsPage {
            SettingsSection(note: "Live renders Markdown as you write; Source shows the plain text. View > Show Source (⌥⌘U) switches a window.") {
                SettingsRow(label: "On launch") {
                    TextChoice(label: "On launch", selection: $preferences.onLaunch, options: [
                        ("Reopen last files", .lastFiles), ("Show the launch window", .launchWindow),
                    ])
                }
                SettingsRow(label: "Open documents in") {
                    TextChoice(label: "Open documents in", selection: $preferences.opensInSource, options: [("Live", false), ("Source", true)])
                }
            }
            SettingsSection(note: "The first save of a new document starts here.") {
                SettingsRow(label: "New files go in") {
                    FolderField(url: preferences.newFileFolder) { preferences.newFileFolder = $0 }
                }
            }
            SettingsSection(title: "Updates", note: updates.updater == nil ? "This build does not update itself." : Updates.lineText) {
                Group {
                    SettingsRow(label: "Check automatically") {
                        OnOff(label: "Check for updates automatically", isOn: Binding { updates.automaticChecks } set: { updates.setAutomaticChecks($0) })
                    }
                    SettingsRow(label: "Beta builds", detail: "Betas also get every stable release.") {
                        OnOff(label: "Get beta builds", isOn: Binding { updates.beta } set: { updates.setBeta($0) })
                    }
                    SettingsRow(label: "Last checked") {
                        HStack(spacing: 14) {
                            Text(updates.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                                .font(Station.mono(12))
                                .foregroundStyle(Station.color(.ink2))
                            // Sparkle starts no check while it holds a staged update.
                            Button("Check Now") { updates.checkNow() }
                                .buttonStyle(.station)
                                .disabled(updates.staged != nil)
                        }
                    }
                }
                .disabled(updates.updater == nil)
                if let error = updates.lastError {
                    SettingsNote(error)
                        .padding(.top, 8)
                }
                if let text = updates.stagedText {
                    Text(text)
                        .font(Station.label)
                        .foregroundStyle(Station.color(.ink))
                        .padding(.top, 8)
                }
            }
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
