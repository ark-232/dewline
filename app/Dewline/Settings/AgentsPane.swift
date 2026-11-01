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
    let store: ThemeStore
    @Environment(\.colorScheme) private var scheme
    @State private var hooks = HookStatus(claude: false, codex: false)
    private let command = HookStatus.installCommand()

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Hooks", note: "A hook tells Dewline which agent wrote a change. Codex runs a new hook only after you trust it: type /hooks in Codex and trust Dewline\u{2019}s.") {
                SettingsRow(label: "Command") {
                    Text(hooks.onPath ?? "Not on your PATH; the app\u{2019}s own runs")
                        .font(hooks.onPath == nil ? Station.label : Station.mono(12))
                        .foregroundStyle(Station.color(.ink2))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(hooks.version ?? "dewline doctor didn\u{2019}t run")
                }
                SettingsRow(label: "Claude Code") { installed(hooks.claude) }
                SettingsRow(label: "Codex") { installed(hooks.codex) }
                SettingsRow(label: "Cursor") { installed(hooks.cursor) }
            }
            SettingsSection(note: "Paste it in Terminal. It runs the dewline command inside this app; reopen Settings to see the result.") {
                SettingsRow(label: "Install hooks") {
                    HStack(spacing: 12) {
                        Text("dewline doctor --install-hooks")
                            .font(Station.mono(12))
                            .foregroundStyle(Station.color(.ink2))
                            .lineLimit(1)
                            .help(command)
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .buttonStyle(.station)
                        .fixedSize()
                    }
                }
            }
            SettingsSection(title: "Unknown writer") {
                SettingsNote("When Dewline can\u{2019}t tell who wrote a change, it labels the change Unknown, with a hollow bead and a dashed underline. Claude Code\u{2019}s Bash edits, Gemini, sync and other apps show up this way, because no hook reports exactly what they wrote.")
            }
            SettingsSection(title: "Writers", trailing: "\(Self.writers.count)", note: "Each writer's changes are marked in its color. A well sets the hue and strength; Dewline keeps the lightness so text on a mark stays readable. A hue within ΔE 8 of a color in your Light or Dark theme shows the clash.") {
                ForEach(Self.writers) { writer in
                    WriterRow(writer: writer, store: store, dark: scheme == .dark)
                }
            }
            RestoreDefaults {
                store.writerHues = store.writerHues.filter { !Self.writers.contains($0.key) }
            }
        }
        .task { hooks = await Task.detached { HookStatus.read() }.value }
    }

    /// Every writer but the collaborator, whose color is in Collaboration, and the demo.
    private static let writers = Writer.allCases.filter { $0 != .collaborator && $0 != .demo }

    /// A filled `ink` dot and "Installed", or a hollow `ink3` ring and "Not installed".
    private func installed(_ on: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(Station.color(on ? .ink : .ink3), lineWidth: 1.25)
                .background(Circle().fill(on ? Station.color(.ink) : .clear))
                .frame(width: 7, height: 7)
            Text(on ? "Installed" : "Not installed")
                .font(Station.label)
                .foregroundStyle(Station.color(on ? .ink : .ink3))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A writer's name set as its insertion mark (a wash under a solid underline, dashed for an unknown app), a color well,
/// and, when a theme color sits within ΔE 8, the clash and a button for the nearest clear hue.
struct WriterRow: View {
    let writer: Writer
    let store: ThemeStore
    let dark: Bool

    var body: some View {
        let color = Color(nsColor: store.writerColor(writer))
        let clash = store.clash(writer)
        let well = Binding {
            color
        } set: { picked in
            if let pick = OKLCH(NSColor(picked)) { store.writerHues[writer] = pick }
        }
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(writer.name)
                        .font(Station.label)
                        .foregroundStyle(Station.color(.ink))
                        .underline(pattern: writer == .unknown ? .dash : .solid, color: color)
                        .padding(.horizontal, 3)
                        .background(color.opacity(dark ? 0.24 : 0.15), in: .rect(cornerRadius: 2))
                    if let clash {
                        Text("Close to \(clash.theme.name)'s \(clash.token.label) in \(clash.dark ? "Dark" : "Light") (ΔE \(clash.deltaE.formatted(.number.precision(.fractionLength(1)))))")
                            .font(Station.small)
                            .foregroundStyle(Station.color(.ink3))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 190, alignment: .leading)
                HStack(spacing: 12) {
                    ColorPicker("\(writer.name) color", selection: well, supportsOpacity: false)
                        .labelsHidden()
                    if let hue = clash?.clearHue {
                        Button {
                            store.writerHues[writer] = hue
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: (dark ? writer.colors(hue).dark : writer.colors(hue).light).color)).frame(width: 8, height: 8)
                                Text("Use Clear Hue")
                            }
                        }
                        .buttonStyle(.station)
                        .help("Moves \(writer.name) to hue \(Int(hue.h.rounded()))°, the nearest one clear of both themes")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(writer.name)
    }
}
