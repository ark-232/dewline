import AppKit
import SwiftUI

/// What `dewline doctor` reports: whether the command runs, from the PATH or else inside the app, and whether each
/// agent's settings carry every hook that names its writes.
struct HookStatus: Equatable, Sendable {
    var claude: Bool
    var codex: Bool
    var cursor = false
    /// The `dewline` on the PATH, if any.
    var onPath: String?
    /// The doctor's version line, or nil when the command didn't run.
    var version: String?

    /// Where Homebrew and the usual installs put commands; an app doesn't get the login shell's PATH.
    private static let pathFolders = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/bin"]

    static func read(
        home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
        bundle: URL = Bundle.main.bundleURL
    ) -> HookStatus {
        let onPath = pathFolders
            .map { ($0 as NSString).expandingTildeInPath + "/dewline" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let process = Process()
        process.executableURL = URL(filePath: onPath ?? bundle.appending(path: "Contents/Helpers/dewline").path)
        process.arguments = ["doctor"]
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return HookStatus(claude: false, codex: false, onPath: onPath) }
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        process.waitUntilExit()
        func installed(_ agent: String) -> Bool {
            lines.contains { $0.hasPrefix("  \(agent): installed in ") }
        }
        return HookStatus(
            claude: installed("Claude Code"), codex: installed("Codex"), cursor: installed("Cursor"), onPath: onPath,
            version: lines.first { $0.hasPrefix("Version: ") }.map { String($0.dropFirst("Version: ".count)) }
        )
    }

    /// The bundled command that installs the hooks, quoted for a shell.
    static func installCommand(bundle: URL = Bundle.main.bundleURL) -> String {
        let path = bundle.appending(path: "Contents/Helpers/dewline").path
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "' doctor --install-hooks"
    }
}

struct AgentsPane: View {
    @State private var hooks = HookStatus(claude: false, codex: false)
    private let command = HookStatus.installCommand()

    var body: some View {
        Form {
            Section {
                LabeledContent("Command") {
                    Text(hooks.onPath ?? "Not on your PATH; the app’s own runs")
                        .foregroundStyle(.secondary)
                        .help(hooks.version ?? "dewline doctor didn’t run")
                }
                LabeledContent("Claude Code") { installed(hooks.claude) }
                LabeledContent("Codex") { installed(hooks.codex) }
                LabeledContent("Cursor") { installed(hooks.cursor) }
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
        .task { hooks = await Task.detached { HookStatus.read() }.value }
    }

    private func installed(_ on: Bool) -> some View {
        Label(on ? "Installed" : "Not installed", systemImage: on ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(on ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }
}
