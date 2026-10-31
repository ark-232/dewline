internal import DewlineFFIBindings
import Foundation

/// One shared document in a live collaboration (D13). Offsets are UTF-16, as NSString counts them.
public final class Share: Sendable {
    public enum Status: Sendable, Equatable {
        case connecting
        /// Joined; the host has not decided.
        case waiting
        case live
        case denied
        case removed
        case failed(String)
    }

    public struct Peer: Sendable, Hashable {
        public let id: String
        public let name: String
    }

    /// One replace that brings the shown text up to the shared text.
    public struct Edit: Sendable {
        public let start: Int
        public let end: Int
        public let text: String
        public let peer: String
        public let name: String
    }

    public struct Cursor: Sendable, Hashable {
        public let peer: String
        public let name: String
        public let offset: Int
    }

    public struct Failure: Error, Sendable {
        public let message: String
    }

    private let collab: Collab

    private init(_ collab: Collab) {
        self.collab = collab
    }

    /// Shares `text` as `fileName`. `changed` runs on a background thread.
    public static func host(nodeKey: Data, name: String, fileName: String, text: String, changed: @escaping @Sendable () -> Void) throws(Failure) -> Share {
        do {
            return Share(try Collab.host(nodeKey: nodeKey, name: name, fileName: fileName, text: text, listener: Listener(changed)))
        } catch {
            throw Failure(message: Self.message(error))
        }
    }

    /// Joins through a `dewline://join` link as `name`.
    public static func join(nodeKey: Data, name: String, link: String, changed: @escaping @Sendable () -> Void) throws(Failure) -> Share {
        do {
            return Share(try Collab.join(nodeKey: nodeKey, name: name, link: link, listener: Listener(changed)))
        } catch {
            throw Failure(message: Self.message(error))
        }
    }

    public static func newNodeKey() -> Data {
        DewlineFFIBindings.newNodeKey()
    }

    private static func message(_ error: any Error) -> String {
        if case CollabError.Failed(let message) = error { return message }
        return "\(error)"
    }

    /// A new one-time join link; nil for a guest.
    public func invite() -> String? {
        collab.invite()
    }

    public var status: Status {
        switch collab.status() {
        case .connecting: .connecting
        case .waiting: .waiting
        case .live: .live
        case .denied: .denied
        case .removed: .removed
        case .failed(let message): .failed(message)
        }
    }

    public var isHost: Bool { collab.isHost() }
    public var fileName: String { collab.fileName() }
    /// The shared text as the app last showed it.
    public var text: String { collab.text() }
    public var shareID: String { collab.shareId() }
    public var documentKey: Data? { collab.documentKey() }
    public var pending: [Peer] { collab.pending().map { Peer(id: $0.id, name: $0.name) } }
    public var peers: [Peer] { collab.peers().map { Peer(id: $0.id, name: $0.name) } }

    public func approve(_ peer: String) { collab.approve(peer: peer) }
    public func deny(_ peer: String) { collab.deny(peer: peer) }
    public func remove(_ peer: String) { collab.remove(peer: peer) }

    /// This Mac's edit to the shown text.
    public func edit(start: Int, end: Int, text: String) throws(Failure) {
        do {
            try collab.edit(start: UInt32(start), end: UInt32(end), text: text)
        } catch {
            throw Failure(message: Self.message(error))
        }
    }

    /// Collaborators' changes since the last pull.
    public func pull() -> Edit? {
        collab.pull().map { Edit(start: Int($0.start), end: Int($0.end), text: $0.text, peer: $0.peer, name: $0.name) }
    }

    public func setCursor(_ offset: Int) {
        collab.setCursor(offset: UInt32(offset))
    }

    public var cursors: [Cursor] {
        collab.cursors().map { Cursor(peer: $0.peer, name: $0.name, offset: Int($0.offset)) }
    }

    public func close() {
        collab.close()
    }
}

private final class Listener: CollabListener {
    private let onChange: @Sendable () -> Void

    init(_ onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func changed() {
        onChange()
    }
}
