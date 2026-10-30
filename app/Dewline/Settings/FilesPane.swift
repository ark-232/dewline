import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilesPane: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Show files .gitignore hides", isOn: $preferences.showsIgnored)
            } footer: {
                Text("They show dimmed in the sidebar. .git, node_modules and dotfiles stay hidden.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Pasted images go", selection: $preferences.attachments) {
                    Text("Beside the document").tag(Preferences.Attachments.beside)
                    Text("In an “attachments” folder beside it").tag(Preferences.Attachments.subfolder)
                }
            }
            Section {
                LabeledContent("Inbox") {
                    HStack(spacing: 8) {
                        Text(abbreviatedPath(preferences.inbox))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(preferences.inbox.path)
                        Button("Choose…") {
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = [UTType("net.daringfireball.markdown") ?? .plainText]
                            panel.directoryURL = preferences.inbox.deletingLastPathComponent()
                            panel.nameFieldStringValue = preferences.inbox.lastPathComponent
                            panel.prompt = "Use"
                            if panel.runModal() == .OK, let url = panel.url { preferences.inbox = url }
                        }
                    }
                }
            } footer: {
                Text("dewline capture adds each entry to the end of this file.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
