import AppKit
import MdCore

/// The files a panel agent reads and writes, inside its session's folder only. A write to an open note is claimed
/// the way an agent's hooks claim one, so the change engine lands it as marked changes with Keep and Revert; the
/// buffer is never written directly.
@MainActor
final class AgentWrites {
    /// The folder's realpath.
    let folder: String
    /// The claims' session: the agent's name, then "#" and an id, so marks can name the agent.
    let session: String
    var documents: @MainActor () -> [MarkdownDocument]
    /// The realpaths written since the turn began.
    private(set) var written: Set<String> = []
    private var engines: [ObjectIdentifier: ChangeEngine] = [:]

    init(folder: URL, agent: String, documents: @escaping @MainActor () -> [MarkdownDocument] = AgentWrites.openDocuments) {
        self.folder = Self.realpath(folder.path) ?? folder.standardizedFileURL.path
        session = Self.session(agent: agent)
        self.documents = documents
    }

    static func openDocuments() -> [MarkdownDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
    }

    /// "Gemini CLI#1a2b3c4d": printable ASCII, as claims' ids must be.
    static func session(agent: String) -> String {
        let name = String(agent.unicodeScalars.filter { (0x20..<0x7F).contains($0.value) && $0 != "#" }.prefix(80).map(Character.init))
        return "\(name.isEmpty ? "Agent" : name)#\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The agent's name in a claim session.
    nonisolated static func name(_ session: String) -> String {
        session.range(of: "#", options: .backwards).map { String(session[..<$0.lowerBound]) } ?? session
    }

    /// The writer whose color the agent's marks take.
    nonisolated static func writer(_ session: String) -> Writer {
        let name = name(session).lowercased()
        return [Writer.gemini, .claude, .codex, .cursor].first { name.contains($0.rawValue) } ?? .demo
    }

    func beginTurn() {
        written = []
    }

    /// The turn ended: each engine that took a claim hears it, as a hook's Stop.
    func endTurn() {
        for engine in engines.values {
            LiveFile.claim(ControlSocket.Claim(vendor: .acp, session: session, event: .turnEnd), engine: engine)
        }
        engines = [:]
    }

    // MARK: fs/read_text_file and fs/write_text_file

    /// The open note's text, unsaved edits included, else the file's; from `line` (from 1) for `limit` lines.
    func read(_ params: JSON) throws(ACPClient.Failure) -> JSON {
        let path = try resolve(params["path"]?.string)
        var text: String
        if let textView = open(path)?.textView {
            text = textView.string
        } else {
            guard let data = FileManager.default.contents(atPath: path) else { throw .invalid("\(path) can't be read") }
            guard let decoded = String(data: data, encoding: .utf8) else { throw .invalid("\(path) is not UTF-8 text") }
            text = decoded
        }
        if params["line"]?.int != nil || params["limit"]?.int != nil {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = min(max((params["line"]?.int ?? 1) - 1, 0), lines.count)
            let end = params["limit"]?.int.map { min(start + max($0, 0), lines.count) } ?? lines.count
            text = lines[start..<end].joined(separator: "\n")
        }
        return ["content": .string(text)]
    }

    /// Writes the file. An open note saves first, so the file holds what the agent read, then takes the write as a
    /// claimed one: PreToolUse with the bytes it declares, the write, PostToolUse.
    func write(_ params: JSON) async throws(ACPClient.Failure) -> JSON {
        let path = try resolve(params["path"]?.string)
        guard let content = params["content"]?.string else { throw .invalid("The write has no content") }
        written.insert(path)
        let after = Data(content.utf8)
        let engine: ChangeEngine?
        let isOpen: Bool
        if let live = open(path)?.live {
            await live.autosave()
            engine = live.engine
            isOpen = true
        } else {
            // A closed note: its engine is the app's, and ClosedChanges keeps what it held so the write lands marked
            // when it opens.
            engine = MarkdownDocument.sharedEngine
            isOpen = false
        }
        let before = FileManager.default.contents(atPath: path)
        guard before != after else { return [:] }
        if !isOpen, let before {
            ClosedChanges.record(path: URL(fileURLWithPath: path), writer: .agent(.acp, session: session), before: before)
        }
        let id = UUID().uuidString
        if let engine {
            claim(.preToolUse(.init(id: id, tool: .write, path: path, hash: before.map(Self.hex), declared: Self.hex(after))), engine)
        }
        do {
            // Compare and swap: nothing else wrote the file since it was read.
            guard FileManager.default.contents(atPath: path) == before else { throw ACPClient.Failure.invalid("\(path) changed while it was written") }
            try after.write(to: URL(fileURLWithPath: path), options: before == nil ? .withoutOverwriting : [])
        } catch let failure as ACPClient.Failure {
            throw failure
        } catch {
            throw .invalid("\(path) can't be written: \(error.localizedDescription)")
        }
        if let engine {
            claim(.postToolUse(.init(id: id, tool: .write, path: path, hash: Self.hex(after), declared: nil)), engine)
        }
        return [:]
    }

    private func claim(_ event: ControlSocket.Claim.Event, _ engine: ChangeEngine) {
        LiveFile.claim(ControlSocket.Claim(vendor: .acp, session: session, event: event), engine: engine)
        engines[ObjectIdentifier(engine)] = engine
    }

    /// The open note at `path`, by realpath.
    func open(_ path: String) -> MarkdownDocument? {
        documents().first { document in
            guard let url = document.live?.url ?? document.fileURL else { return false }
            return Self.realpath(url.path) == path
        }
    }

    // MARK: Paths

    /// The realpath of `path`, which must lie inside the folder and, inside the home folder, pass the agents' jail
    /// (never ~/Library or a .ssh folder). A file that doesn't exist yet resolves by its folder.
    func resolve(_ path: String?) throws(ACPClient.Failure) -> String {
        guard let path, path.hasPrefix("/") else { throw .invalid("The path is not absolute") }
        let resolved: String
        if let real = Self.realpath(path) {
            resolved = real
        } else {
            let name = (path as NSString).lastPathComponent
            guard name != "..", name != ".", let parent = Self.realpath((path as NSString).deletingLastPathComponent) else {
                throw .invalid("\(path) is not in a folder that exists")
            }
            resolved = (parent as NSString).appendingPathComponent(name)
        }
        guard resolved.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") else {
            throw .invalid("\(path) is outside the folder Dewline opened")
        }
        let home = Self.realpath(NSHomeDirectory()) ?? NSHomeDirectory()
        if resolved.hasPrefix(home + "/") {
            do {
                _ = try jailedPath(resolved)
            } catch {
                throw .invalid("\(path) is a place agents can't reach")
            }
        }
        return resolved
    }

    static func realpath(_ path: String) -> String? {
        guard let real = Darwin.realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    static func hex(_ data: Data) -> String {
        contentHash(data).map { String(format: "%02x", $0) }.joined()
    }
}
