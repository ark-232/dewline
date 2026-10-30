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

    public struct Opened: Sendable {
        public let doc: UInt64
        /// None when the file is not UTF-8 text.
        public let text: String?
        /// Whether the file starts with a byte-order mark, which `text` leaves out.
        public let bom: Bool
    }

    /// Replaces `range` with `text`; `change` names the pending change it makes.
    public struct Edit: Sendable, Equatable {
        public let change: UInt64
        public let range: NSRange
        public let text: String
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
        guard case .text(let text, let bom) = opened.contents else { return Opened(doc: opened.doc, text: nil, bom: false) }
        return Opened(doc: opened.doc, text: text, bom: bom)
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
            marked: landing.marked,
            edits: landing.edits.map { Edit(change: $0.change, range: range($0.edit.start, $0.edit.end), text: $0.edit.text) },
            covering: landing.covering.map { Edit(change: 0, range: range($0.start, $0.end), text: $0.text) },
            conflicts: landing.conflicts.map { Conflict(change: $0.change, range: range($0.start, $0.end), theirs: $0.theirs) }
        )
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

    /// The document's file is now at `url`.
    public func moved(_ doc: UInt64, to url: URL) throws(Failure) {
        _ = try Self.call { try engine.moved(doc: doc, to: url.path) }
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
