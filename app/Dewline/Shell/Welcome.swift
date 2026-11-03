import AppKit
import MdCore

/// Welcome.md: the bundled guide, written once into the notes folder, where it is a note like any other.
@MainActor
enum Welcome {
    /// True once the first launch wrote the guide and opened the notes folder.
    static let shownKey = "DewlineWelcomeShown"
    /// The sentence the demo extends, in the paragraph that holds its link, and what it adds.
    static let paragraph = "Dewline marks each change so you can keep or revert it."
    static let addition = " This sentence came from outside the editor, the way an agent\u{2019}s edit arrives."

    static var bundled: URL {
        Bundle.main.url(forResource: "Welcome", withExtension: "md")!
    }

    static func url(in folder: URL = FileActions.notesFolder) -> URL {
        folder.appending(path: "Welcome.md")
    }

    /// Writes the bundled guide into `folder` unless a Welcome.md is already there; true when it wrote one.
    @discardableResult
    static func write(in folder: URL = FileActions.notesFolder) throws -> Bool {
        let url = url(in: folder)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: bundled).write(to: url, options: .withoutOverwriting)
        return true
    }
}

/// "Show me a change" in Welcome.md: a writer named Demo extends the paragraph that holds the link through the change
/// engine, claimed as an agent's hooks claim a write, so it lands marked with Keep and Revert where the reader is
/// looking.
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
            // Long enough to see the paragraph change after the click.
            try? await Task.sleep(for: .milliseconds(400))
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

    /// Stops listening once Demo's change has landed and been kept or reverted.
    private func changed(_ live: LiveFile) {
        let pending = live.changes.values.contains { change in
            if case .agent(.demo, _) = change.origin { change.marked } else { false }
        }
        if pending { landed = true } else if landed { stop() }
    }

    private static func hex(_ data: Data) -> String {
        contentHash(data).map { String(format: "%02x", $0) }.joined()
    }
}
