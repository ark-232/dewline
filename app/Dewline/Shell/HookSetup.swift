import AppKit

/// Set Up for agent hooks: lists the settings files `dewline doctor --install-hooks` would change, and on Set Up runs
/// it from the app's bundle, answering its questions yes. The command asks only on a terminal, so it runs on a
/// pseudo-terminal of its own.
@MainActor
enum HookSetup {
    /// Agent settings missing a hook, from `dewline doctor`: "Claude Code" and the file it would change.
    struct Missing: Equatable {
        let agent: String
        let file: String
    }

    static func command(bundle: URL = Bundle.main.bundleURL) -> URL {
        bundle.appending(path: "Contents/Helpers/dewline")
    }

    /// Reads the doctor's "  Claude Code: PreToolUse, Stop missing from /Users/a/.claude/settings.json" lines.
    static func missing(in report: String) -> [Missing] {
        report.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  "), let colon = line.firstIndex(of: ":"), let from = line.range(of: " missing from ") else { return nil }
            let agent = line[line.index(line.startIndex, offsetBy: 2)..<colon]
            return Missing(agent: String(agent), file: String(line[from.upperBound...]))
        }
    }

    /// Settings > Agents > Set Up…, and the Keep bar's offer: a sheet on `window` naming each file, then the run.
    static func install(from window: NSWindow?, command: URL = command(), done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Task {
            let report = await run(command, ["doctor"], answers: 0)
            let missing = Self.missing(in: report.output)
            let alert = NSAlert()
            guard report.ran else {
                alert.messageText = "Dewline couldn\u{2019}t run its dewline command."
                alert.informativeText = "Reinstall Dewline, then try again."
                return present(alert, on: window) { _ in done(false) }
            }
            guard !missing.isEmpty else {
                alert.messageText = "Agent edits are already marked."
                alert.informativeText = "Every agent Dewline knows has its hooks."
                return present(alert, on: window) { _ in done(true) }
            }
            alert.messageText = "Mark your agents\u{2019} edits"
            alert.informativeText = "Dewline adds a hook to each file below, so it knows which agent wrote a change.\n\n"
                + missing.map { "\($0.agent): \(($0.file as NSString).abbreviatingWithTildeInPath)" }.joined(separator: "\n")
            alert.addButton(withTitle: "Set Up")
            alert.addButton(withTitle: "Cancel")
            present(alert, on: window) { response in
                guard response == .alertFirstButtonReturn else { return done(false) }
                Task {
                    let result = await run(command, ["doctor", "--install-hooks"], answers: missing.count)
                    let after = await run(command, ["doctor"], answers: 0)
                    done(result.ran && Self.missing(in: after.output).isEmpty)
                }
            }
        }
    }

    private static func present(_ alert: NSAlert, on window: NSWindow?, _ handler: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { handler(response) } }
        } else {
            handler(alert.runModal())
        }
    }

    /// Runs `command` with `arguments` on a pseudo-terminal, typing "y" and Return `answers` times.
    static func run(_ command: URL, _ arguments: [String], answers: Int) async -> (ran: Bool, output: String) {
        await Task.detached {
            var main: Int32 = -1
            var side: Int32 = -1
            guard openpty(&main, &side, nil, nil, nil) == 0 else { return (false, "") }
            let process = Process()
            process.executableURL = command
            process.arguments = arguments
            let terminal = FileHandle(fileDescriptor: side, closeOnDealloc: true)
            process.standardInput = terminal
            process.standardOutput = terminal
            process.standardError = terminal
            let reader = FileHandle(fileDescriptor: main, closeOnDealloc: true)
            do {
                try process.run()
            } catch {
                return (false, "")
            }
            try? terminal.close()
            if answers > 0 { reader.write(Data(String(repeating: "y\n", count: answers).utf8)) }
            var output = Data()
            // The terminal reports EIO once the command and its children have closed their side.
            while let chunk = try? reader.read(upToCount: 4096), !chunk.isEmpty { output.append(chunk) }
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: output, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n"))
        }.value
    }
}
