import AppKit
import SwiftUI

/// Whether Claude Code's and Codex's settings run `dewline notify`, the hook that names their writes.
struct HookStatus: Equatable {
    var claude: Bool
    var codex: Bool

    static func read(home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)) -> HookStatus {
        func runsDewline(_ path: String) -> Bool {
            (try? String(contentsOf: home.appending(path: path), encoding: .utf8))?.contains("dewline notify") == true
        }
        return HookStatus(
            claude: runsDewline(".claude/settings.json"),
            codex: runsDewline(".codex/hooks.json") || runsDewline(".codex/config.toml")
        )
    }

    /// The bundled command that installs the hooks, quoted for a shell.
    static func installCommand(bundle: URL = Bundle.main.bundleURL) -> String {
        let path = bundle.appending(path: "Contents/Helpers/dewline").path
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "' doctor --install-hooks"
    }
}

struct AgentsPane: View {
    @State private var hooks = HookStatus.read()
    private let command = HookStatus.installCommand()

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code") { installed(hooks.claude) }
                LabeledContent("Codex") { installed(hooks.codex) }
            } header: {
                Text("Hooks")
            } footer: {
                Text("A hook tells Dewline which agent wrote a change. Codex runs a new hook only after you trust it: type /hooks in Codex and trust Dewline’s.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Install hooks") {
                    HStack(spacing: 8) {
                        Text("dewline doctor --install-hooks")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help(command)
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                }
            } footer: {
                Text("Paste it in Terminal. It runs the dewline command inside this app; reopen Settings to see the result.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Text("When Dewline can’t tell who wrote a change, it labels the change Unknown, with a hollow bead and a dashed underline. Claude Code’s Bash edits, Cursor, Gemini, sync and other apps show up this way, because no hook reports exactly what they wrote.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Unknown writer")
            }
        }
        .onAppear { hooks = .read() }
    }

    private func installed(_ on: Bool) -> some View {
        Label(on ? "Installed" : "Not installed", systemImage: on ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(on ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }
}
