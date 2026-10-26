import SwiftUI

struct UpdatesPane: View {
    let updates: Updates

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: Binding { updates.automaticChecks } set: { updates.setAutomaticChecks($0) })
                Toggle("Get beta builds", isOn: Binding { updates.beta } set: { updates.setBeta($0) })
            } footer: {
                Text(updates.updater == nil ? "This build does not update itself." : Updates.lineText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Last checked") {
                    Text(updates.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                }
                if let error = updates.lastError {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                if let text = updates.stagedText {
                    Text(text)
                }
                // Sparkle starts no check while it holds a staged update.
                Button("Check Now") { updates.checkNow() }
                    .disabled(updates.staged != nil)
            }
        }
        .disabled(updates.updater == nil)
    }
}
