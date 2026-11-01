import AppKit
import MdCore

/// Welcome.md: the bundled guide, opened from a copy in Application Support that the reader owns.
enum Welcome {
    /// True once the guide has opened on a first launch.
    static let shownKey = "DewlineWelcomeShown"
    /// The paragraph the demo edits, and what it adds.
    static let paragraph = "This paragraph is plain text in a Markdown file on your Mac. Any app can read it, and any app can change it."
    static let addition = " Demo added this sentence from outside the editor, the way an agent writes to a file you have open."
    static let tip = "*Demo changed this paragraph. Keep it (⌘↩) or Revert it (⌥⌘⌫).*"
    static let done = "*Done. Changes from Claude Code, Codex or Cursor show up the same way.*"
    /// The heading the tip goes above.
    static let tryIt = "## Try it with your agent"

    static var bundled: URL {
        Bundle.main.url(forResource: "Welcome", withExtension: "md")!
    }

    static var url: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.arkwerx.dewline")
            .appending(path: "Welcome.md")
    }

    /// Writes the bundled guide to `url`, with that file's path in its agent prompt. An existing copy keeps its edits
    /// unless `fresh`.
    static func copy(to url: URL = url, fresh: Bool) throws {
        guard fresh || !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try String(contentsOf: bundled, encoding: .utf8).replacingOccurrences(of: "{path}", with: url.path)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// The first-run demo: about 3 s after Welcome.md opens, a writer named Demo edits its paragraph through the change
/// engine, claimed as an agent's hooks claim a write, so it lands marked with Keep and Revert. A tip line arrives under
/// it as a quiet outside write, and becomes the done line once the change is decided.
@MainActor
final class WelcomeDemo {
    private static var running: WelcomeDemo?

    private weak var document: MarkdownDocument?
    private let url: URL
    private var observer: (any NSObjectProtocol)?
    private var start: Task<Void, Never>?
    private var landed = false

    private init(_ document: MarkdownDocument, url: URL) {
        self.document = document
        self.url = url
    }

    static func play(_ document: MarkdownDocument, at url: URL) {
        running?.stop()
        let demo = WelcomeDemo(document, url: url)
        running = demo
        demo.observer = NotificationCenter.default.addObserver(forName: LiveFile.changesDidChange, object: nil, queue: .main) { [weak demo] note in
            let live = note.object as? LiveFile
            MainActor.assumeIsolated {
                guard let demo, let live, live === demo.document?.live else { return }
                demo.changed(live)
            }
        }
        demo.start = Task { [weak demo] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            demo?.write()
        }
    }

    private func stop() {
        start?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if Self.running === self { Self.running = nil }
    }

    /// Demo's claimed write: PreToolUse with the bytes it declares, the write, PostToolUse, then the turn's end.
    private func write() {
        guard let engine = document?.live?.engine, let before = try? Data(contentsOf: url),
            let real = realpath(url.path, nil)
        else { return stop() }
        let path = String(cString: real)
        free(real)
        let text = String(decoding: before, as: UTF8.self)
        guard text.contains(Welcome.paragraph), !text.contains(Welcome.paragraph + Welcome.addition) else { return stop() }
        let after = Data(text.replacingOccurrences(of: Welcome.paragraph, with: Welcome.paragraph + Welcome.addition).utf8)
        let id = UUID().uuidString
        func claim(_ event: ControlSocket.Claim.Event) {
            LiveFile.claim(ControlSocket.Claim(vendor: .demo, session: "welcome", event: event), engine: engine)
        }
        claim(.preToolUse(.init(id: id, tool: .write, path: path, hash: Self.hex(before), declared: Self.hex(after))))
        do {
            try after.write(to: url)
        } catch {
            return stop()
        }
        claim(.postToolUse(.init(id: id, tool: .write, path: path, hash: Self.hex(after), declared: nil)))
        claim(.turnEnd)
    }

    private func changed(_ live: LiveFile) {
        let pending = live.changes.values.contains { change in
            if case .agent(.demo, _) = change.origin { change.marked } else { false }
        }
        if pending, !landed {
            landed = true
            rewrite { $0.replacingOccurrences(of: Welcome.tryIt, with: Welcome.tip + "\n\n" + Welcome.tryIt) }
        } else if !pending, landed {
            stop()
            // The decision is an edit; once it is saved, the file takes the done line as a quiet outside write.
            Task {
                guard await live.autosave() == nil else { return }
                rewrite { $0.replacingOccurrences(of: Welcome.tip, with: Welcome.done) }
            }
        }
    }

    /// Rewrites the file from outside the editor. With the buffer saved, the engine lands it quietly, unmarked.
    private func rewrite(_ change: @escaping (String) -> String) {
        let url = url
        Task {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let new = change(text)
            if new != text { try? Data(new.utf8).write(to: url) }
        }
    }

    private static func hex(_ data: Data) -> String {
        contentHash(data).map { String(format: "%02x", $0) }.joined()
    }
}
