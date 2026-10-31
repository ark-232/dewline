internal import DewlineFFIBindings
import Foundation

/// The change engine (core::engine): lands outside writes into open documents and saves them through the file's
/// compare-and-swap. Offsets are UTF-16, as NSString counts them. `commit` is safe on the main thread; every other
/// call reads or writes files or the snapshot store, so it runs off it.
public final class ChangeEngine: Sendable {
    private let engine: Engine

    /// Why a call did nothing.
    public enum Failure: Error, Sendable, Equatable {
        case closed
        /// A hook call or git's index lock holds the file: land again shortly.
        case waiting
        case notText
        case stale
        case io(String)
    }

    /// Why a save wrote nothing.
    public enum Refusal: Error, Sendable, Equatable {
        case closed, readOnly, stale, conflict, changed, held, composing, writingTools, deleted, unreadable
        case io(String)
    }

    public enum SaveKind: Sendable {
        case auto(composing: Bool, writingTools: Bool)
        case explicit
    }

    public enum Bias: Sendable {
        case before, after
    }

    /// Who wrote a change or a snapshot.
    public enum Origin: Sendable, Equatable {
        case user
        case agent(Vendor, session: String)
        /// `action` names what git did, such as "Switched branch".
        case git(action: String?)
        /// "Unknown app".
        case external
        /// Someone editing the shared file live, by node id and the name the host approved.
        case collaborator(peer: String, name: String)
    }

    public enum Vendor: Sendable, Equatable {
        case claude, codex, cursor
    }

    public enum Decision: Sendable {
        /// Your text stays.
        case keep
        /// The other version replaces it.
        case other
        case both
    }

    /// What a claim changed, by document.
    public enum Update: Sendable, Equatable {
        /// A late claim named a change already landed; a quiet one is now marked.
        case relabeled(doc: UInt64, change: UInt64, origin: Origin)
        /// A hold ended: run a refused autosave again.
        case released(doc: UInt64)
        /// A hook call ended: land again.
        case retry(doc: UInt64)
    }

    /// A version of a file the store keeps.
    public struct Snapshot: Sendable, Equatable {
        public let id: UInt64
        public let time: Date
        public let origin: Origin
        public let pinned: Bool
        fileprivate let hash: Data
        fileprivate let label: String
    }

    public struct Opened: Sendable {
        public let doc: UInt64
        /// None when the file is not UTF-8 text.
        public let text: String?
        /// Whether the file starts with a byte-order mark, which `text` leaves out.
        public let bom: Bool
        /// The repository's gitdir, to watch and pass to `gitChanged`.
        public let gitdir: URL?
    }

    /// Replaces `range` with `text`; `change` names the pending change it makes.
    public struct Edit: Sendable, Equatable {
        public let change: UInt64
        public let range: NSRange
        public let text: String

        public init(change: UInt64 = 0, range: NSRange, text: String) {
            self.change = change
            self.range = range
            self.text = text
        }
    }

    /// Lines both sides changed: yours stay at `range`, `theirs` is the other version.
    public struct Conflict: Sendable, Equatable {
        public let change: UInt64
        public let range: NSRange
        public let theirs: String
    }

    /// A file's new version merged into the buffer at `version`. Commit it with the buffer still at `version`, and
    /// only then apply `covering` when present, else `edits`.
    public struct Landing: Sendable {
        public let id: UInt64
        public let version: UInt64
        public let origin: Origin
        /// False for a quiet base.
        public let marked: Bool
        public let edits: [Edit]
        /// One replace making the same text as `edits`, for big changes; its `change` is 0.
        public let covering: Edit?
        public let conflicts: [Conflict]
    }

    /// An engine whose snapshots live in `store`.
    public init(store: URL) throws(Failure) {
        engine = try Self.call { try Engine(store: store.path) }
    }

    public func open(_ url: URL) throws(Failure) -> Opened {
        let opened = try Self.call { try engine.open(path: url.path) }
        let gitdir = opened.gitdir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard case .text(let text, let bom) = opened.contents else {
            return Opened(doc: opened.doc, text: nil, bom: false, gitdir: gitdir)
        }
        return Opened(doc: opened.doc, text: text, bom: bom, gitdir: gitdir)
    }

    /// Whether the file differs from the base.
    public func observe(_ doc: UInt64) throws(Failure) -> Bool {
        try Self.call { try engine.observe(doc: doc) }
    }

    public func land(_ doc: UInt64, buffer: String, version: UInt64) throws(Failure) -> Landing? {
        guard let landing = try Self.call({ try engine.land(doc: doc, buffer: buffer, version: version) }) else { return nil }
        func range(_ start: UInt32, _ end: UInt32) -> NSRange {
            NSRange(location: Int(start), length: Int(end - start))
        }
        return Landing(
            id: landing.id,
            version: landing.version,
            origin: Origin(landing.origin),
            marked: landing.marked,
            edits: landing.edits.map { Edit(change: $0.change, range: range($0.edit.start, $0.edit.end), text: $0.edit.text) },
            covering: landing.covering.map { Edit(change: 0, range: range($0.start, $0.end), text: $0.text) },
            conflicts: landing.conflicts.map { Conflict(change: $0.change, range: range($0.start, $0.end), theirs: $0.theirs) }
        )
    }

    /// A collaborator's `edits` to `buffer` (in order, apart), snapshotting a buffer that differs from the file first,
    /// to apply in one step once no IME composition is open.
    public func collaborate(_ doc: UInt64, buffer: String, edits: [Edit]) throws(Failure) -> [Edit] {
        let edits = edits.map { DewlineFFIBindings.Edit(start: UInt32($0.range.location), end: UInt32(NSMaxRange($0.range)), text: $0.text) }
        return try Self.call { try engine.collaborate(doc: doc, buffer: buffer, edits: edits) }
            .map { Edit(range: NSRange(location: Int($0.start), length: Int($0.end - $0.start)), text: $0.text) }
    }

    /// On the main thread, in the step that applies the landing: false when it is no longer the current one.
    public func commit(_ doc: UInt64, landing: UInt64) -> Bool {
        (try? engine.commit(doc: doc, landing: landing)) != nil
    }

    /// Writes `buffer`, stamped with its `version`, and returns the hash of the bytes written.
    public func save(_ doc: UInt64, buffer: String, version: UInt64, kind: SaveKind) throws(Refusal) -> Data {
        let kind: DewlineFFIBindings.SaveKind = switch kind {
        case .auto(let composing, let writingTools): .auto(composing: composing, writingTools: writingTools)
        case .explicit: .explicit
        }
        do {
            return try engine.save(doc: doc, buffer: buffer, version: version, kind: kind)
        } catch let refused as SaveRefused {
            throw switch refused {
            case .Closed: .closed
            case .ReadOnly: .readOnly
            case .Stale: .stale
            case .Conflict: .conflict
            case .Changed: .changed
            case .Held: .held
            case .Composing: .composing
            case .WritingTools: .writingTools
            case .Deleted: .deleted
            case .Unreadable: .unreadable
            case .Io(let message): .io(message)
            }
        } catch {
            throw .io("\(error)")
        }
    }

    /// The document's file is now at `url`; returns its repository's gitdir. Snapshot ids change.
    public func moved(_ doc: UInt64, to url: URL) throws(Failure) -> URL? {
        try Self.call { try engine.moved(doc: doc, to: url.path) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The text that replaces the change's live range, whose text is `current`; nil when the buffer stays as it is.
    /// Reads no file, so it is safe on the main thread.
    public func decide(_ doc: UInt64, change: UInt64, decision: Decision, current: String) -> String? {
        let decision: DewlineFFIBindings.Decision = switch decision {
        case .keep: .keep
        case .other: .other
        case .both: .both
        }
        return engine.decide(doc: doc, change: change, decision: decision, current: current)
    }

    /// A `dewline notify` line's fields, which only label changes. A refused claim changes nothing.
    public func claim(
        event: String, vendor: String, session: String, toolUseId: String?, tool: String?, path: String?, hash: String?,
        declared: String?
    ) -> [Update] {
        let fields = ClaimFields(
            event: event, vendor: vendor, session: session, toolUseId: toolUseId, tool: tool, path: path, hash: hash,
            declared: declared)
        guard let updates = try? engine.claim(fields: fields) else { return [] }
        return updates.map { update in
            switch update {
            case .relabeled(let doc, let change, let origin): .relabeled(doc: doc, change: change, origin: Origin(origin))
            case .released(let doc): .released(doc: doc)
            case .retry(let doc): .retry(doc: doc)
            }
        }
    }

    /// The documents in the gitdir's repository, to land again.
    public func gitChanged(_ gitdir: URL) -> [UInt64] {
        engine.gitChanged(gitdir: gitdir.path)
    }

    /// Newest first.
    public func snapshots(_ doc: UInt64) throws(Failure) -> [Snapshot] {
        try Self.call { try engine.snapshots(doc: doc) }.map {
            Snapshot(id: $0.id, time: $0.time, origin: Origin($0.origin), pinned: $0.pinned, hash: $0.hash, label: $0.label)
        }
    }

    public func pin(_ doc: UInt64, snapshot: Snapshot, pinned: Bool) throws(Failure) {
        try Self.call { try engine.pin(doc: doc, snapshot: snapshot.ffi, pinned: pinned) }
    }

    /// The snapshot's text, to replace the buffer as one undoable edit. The buffer is snapshotted first.
    public func restore(_ doc: UInt64, snapshot: Snapshot, buffer: String) throws(Failure) -> String {
        try Self.call { try engine.restore(doc: doc, snapshot: snapshot.ffi, buffer: buffer) }
    }

    /// Once, after the documents of the last session are open again.
    public func prune() throws(Failure) {
        try Self.call { try engine.prune() }
    }

    public func close(_ doc: UInt64) {
        engine.close(doc: doc)
    }

    /// Maps `offset` through `edits`, in order and not overlapping.
    public static func map(_ offset: Int, through edits: [Edit], bias: Bias) -> Int {
        let edits = edits.map {
            DewlineFFIBindings.Edit(start: UInt32($0.range.location), end: UInt32(NSMaxRange($0.range)), text: $0.text)
        }
        let mapped = try? mapOffset(edits: edits, offset: UInt32(offset), bias: bias == .before ? .before : .after)
        return mapped.map(Int.init) ?? offset
    }

    /// Moves an undo history, oldest entry first, each the edits that undo one action, past `edits` the engine made.
    /// The first entry from the newest that the engine touched is dropped with everything older.
    public static func mapUndo(_ undo: [[Edit]], through edits: [Edit]) -> [[Edit]] {
        func ffi(_ edits: [Edit]) -> [DewlineFFIBindings.Edit] {
            edits.map { DewlineFFIBindings.Edit(start: UInt32($0.range.location), end: UInt32(NSMaxRange($0.range)), text: $0.text) }
        }
        guard let mapped = try? DewlineFFIBindings.mapUndo(undo: undo.map(ffi), edits: ffi(edits)) else { return [] }
        return mapped.map { entry in
            entry.map { Edit(range: NSRange(location: Int($0.start), length: Int($0.end - $0.start)), text: $0.text) }
        }
    }

    private static func call<T>(_ body: () throws -> T) throws(Failure) -> T {
        do {
            return try body()
        } catch let error as EngineError {
            throw switch error {
            case .Closed: .closed
            case .Waiting: .waiting
            case .NotText: .notText
            case .Stale: .stale
            case .Invalid(let message), .Io(let message): .io(message)
            }
        } catch {
            throw .io("\(error)")
        }
    }
}

extension ChangeEngine.Origin {
    fileprivate init(_ origin: DewlineFFIBindings.Origin) {
        self = switch origin {
        case .user: .user
        case .agent(let vendor, let session): .agent(ChangeEngine.Vendor(vendor), session: session)
        case .git(let action): .git(action: action)
        case .external: .external
        case .collaborator(let peer, let name): .collaborator(peer: peer, name: name)
        }
    }

    fileprivate var ffi: DewlineFFIBindings.Origin {
        switch self {
        case .user: .user
        case .agent(let vendor, let session): .agent(vendor: vendor.ffi, session: session)
        case .git(let action): .git(action: action)
        case .external: .external
        case .collaborator(let peer, let name): .collaborator(peer: peer, name: name)
        }
    }
}

extension ChangeEngine.Vendor {
    fileprivate init(_ vendor: DewlineFFIBindings.Vendor) {
        self = switch vendor {
        case .claude: .claude
        case .codex: .codex
        case .cursor: .cursor
        }
    }

    fileprivate var ffi: DewlineFFIBindings.Vendor {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .cursor: .cursor
        }
    }
}

extension ChangeEngine.Snapshot {
    fileprivate var ffi: DewlineFFIBindings.Snapshot {
        DewlineFFIBindings.Snapshot(id: id, hash: hash, time: time, origin: origin.ffi, label: label, pinned: pinned)
    }
}
