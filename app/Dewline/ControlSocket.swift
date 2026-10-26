import Foundation
import Synchronization

/// The socket the `dewline` command (core/crates/cli) talks to, in a folder only this user can enter. A connection
/// carries one request, a JSON line such as `{"v":1,"op":"open","path":"/Users/me/plan.md","line":12,"col":4,
/// "wait":true}`. The answers are JSON lines too: `{"reply":"opened","v":1}`, then `{"reply":"closed","v":1}` once
/// the document closes if the request waits, or `{"error":"not_a_file","reply":"error","v":1}`. Only absolute paths
/// of existing regular files get through, and nothing that arrives here writes to a file.
final class ControlSocket: @unchecked Sendable {
    struct Open: Sendable, Equatable {
        let path: String
        let line: Int?
        let column: Int?
        let wait: Bool
    }

    /// Why a request was refused, as its `error` field names it.
    enum Failure: String, Error {
        case malformed
        case tooLong = "too_long"
        case version
        case unknownOp = "unknown_op"
        case notAbsolute = "not_absolute"
        case notFound = "not_found"
        case notAFile = "not_a_file"
        case cannotOpen = "cannot_open"
    }

    enum Reply: Sendable, Equatable {
        case opened
        case closed
        case refused(Failure, message: String? = nil)
    }

    enum StartError: Error, Equatable {
        case pathTooLong
        /// The socket's folder is a symlink, not a folder, or someone else's.
        case unsafeFolder
        /// Another Dewline answers on the socket.
        case inUse
        case system(String, Int32)
    }

    static let version = 1
    /// The longest request, newline included.
    static let maxRequest = 16 * 1024
    static let maxConnections = 16
    /// How long a connection has to send its request.
    static let requestDeadline = DispatchTimeInterval.seconds(2)

    /// Where the command looks.
    static var standardPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "dev.arkwerx.dewline/run/control.sock").path
    }

    let path: String
    private let uid: uid_t
    private let handler: @MainActor @Sendable (Open, Connection) -> Void
    private let queue = DispatchQueue(label: "dev.arkwerx.dewline.control")
    // Touched only on `queue`.
    private var listener: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var socketFile: (device: dev_t, inode: ino_t)?

    /// Only `uid` may connect. The handler gets each valid request on the main actor and must reply to it.
    init(path: String, uid: uid_t = geteuid(), handler: @escaping @MainActor @Sendable (Open, Connection) -> Void) {
        self.path = path
        self.uid = uid
        self.handler = handler
    }

    /// Listens at `path`, in a folder made private to this user, unless another Dewline still answers there.
    func start() throws {
        guard var address = Self.address(of: path) else { throw StartError.pathTooLong }
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder, &info) == 0 else { throw StartError.system("lstat", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw StartError.unsafeFolder }
        if info.st_mode & 0o077 != 0, chmod(folder, 0o700) != 0 { throw StartError.system("chmod", errno) }
        if Self.answers(address) { throw StartError.inUse }
        if unlink(path) != 0, errno != ENOENT { throw StartError.system("unlink", errno) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Nobody else can reach into the folder, so the socket's mode before chmod is never exposed.
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0, lstat(path, &info) == 0,
            fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
        else {
            let error = errno
            close(fd)
            throw StartError.system("listen", error)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        queue.sync {
            socketFile = (info.st_dev, info.st_ino)
            listener = source
        }
        source.resume()
    }

    /// Stops listening, removes the socket file and drops every connection, so a `dewline open --wait` still
    /// waiting exits with an error.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in Array(connections.values) {
                drop(connection)
            }
            var info = stat()
            if let socketFile, lstat(path, &info) == 0, info.st_dev == socketFile.device, info.st_ino == socketFile.inode {
                unlink(path)
            }
            socketFile = nil
        }
    }

    /// The request in `line`, without its newline, when it is well formed and names an absolute path.
    static func parse(_ line: Data) -> Result<Open, Failure> {
        struct Wire: Decodable {
            let v: Int
            let op: String
            let path: String?
            let line: Int?
            let col: Int?
            let wait: Bool?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: line) else { return .failure(.malformed) }
        guard wire.v == version else { return .failure(.version) }
        guard wire.op == "open" else { return .failure(.unknownOp) }
        guard let path = wire.path, !path.utf8.contains(0), path.utf8.count < PATH_MAX,
            wire.line ?? 1 >= 1, wire.col ?? 1 >= 1, wire.line != nil || wire.col == nil
        else { return .failure(.malformed) }
        guard path.hasPrefix("/") else { return .failure(.notAbsolute) }
        return .success(Open(path: path, line: wire.line, column: wire.col, wait: wire.wait ?? false))
    }

    /// Why `path` can't be opened, or nil when it names an existing regular file.
    static func refusal(of path: String) -> Failure? {
        var info = stat()
        guard stat(path, &info) == 0 else { return .notFound }
        return info.st_mode & S_IFMT == S_IFREG ? nil : .notAFile
    }

    static func address(of path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func answers(_ address: sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func accept(on listening: Int32) {
        while true {
            let fd = Darwin.accept(listening, nil, nil)
            guard fd >= 0 else { return }
            var peer = uid_t()
            var group = gid_t()
            guard getpeereid(fd, &peer, &group) == 0, peer == uid else {
                close(fd)
                continue
            }
            var on: Int32 = 1
            guard connections.count < Self.maxConnections,
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
                fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            else {
                close(fd)
                continue
            }
            let connection = Connection(fd: fd, socket: self)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                if let self, let connection { self.read(connection) }
            }
            source.setCancelHandler { close(fd) }
            connection.source = source
            connections[ObjectIdentifier(connection)] = connection
            source.resume()
            queue.asyncAfter(deadline: .now() + Self.requestDeadline) { [weak self, weak connection] in
                if let self, let connection, connection.request == nil { self.drop(connection) }
            }
        }
    }

    private func read(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        // The client hung up, or sent more than its one request.
        guard count > 0, connection.request == nil else { return drop(connection) }
        connection.buffer += chunk[..<count]
        guard let end = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) else {
            if connection.buffer.count >= Self.maxRequest { send(.refused(.tooLong), to: connection) }
            return
        }
        guard end < Self.maxRequest else { return send(.refused(.tooLong), to: connection) }
        guard end == connection.buffer.count - 1 else { return send(.refused(.malformed), to: connection) }
        switch Self.parse(Data(connection.buffer[..<end])) {
        case .failure(let failure):
            send(.refused(failure), to: connection)
        case .success(let open):
            connection.request = open
            connection.buffer = []
            let handler = handler
            // stat can hang on a dead network volume, and this queue has to stay free for other clients and stop().
            DispatchQueue.global().async { [weak self] in
                let refusal = Self.refusal(of: open.path)
                guard let self else { return }
                self.queue.async {
                    if let refusal {
                        self.send(.refused(refusal), to: connection)
                    } else if connection.isOpen {
                        Task { @MainActor in handler(open, connection) }
                    }
                }
            }
        }
    }

    /// Writes `reply`, then closes the connection unless it is `opened` for a request that waits.
    private func send(_ reply: Reply, to connection: Connection) {
        guard connection.isOpen else { return }
        let line = reply.line
        let written = line.withUnsafeBytes { write(connection.fd, $0.baseAddress, $0.count) }
        if written != line.count || reply != .opened || connection.request?.wait != true {
            drop(connection)
        }
    }

    private func drop(_ connection: Connection) {
        guard connection.isOpen else { return }
        connection.openFlag.store(false, ordering: .relaxed)
        // The source's cancel handler closes the descriptor.
        connection.source?.cancel()
        connection.source = nil
        connections[ObjectIdentifier(connection)] = nil
    }

    /// One client. `reply` may be called from any thread.
    final class Connection: @unchecked Sendable {
        fileprivate let fd: Int32
        fileprivate weak var socket: ControlSocket?
        fileprivate let openFlag = Atomic(true)
        // Touched only on the socket's queue.
        fileprivate var source: DispatchSourceRead?
        fileprivate var buffer: [UInt8] = []
        fileprivate var request: Open?

        fileprivate init(fd: Int32, socket: ControlSocket) {
            self.fd = fd
            self.socket = socket
        }

        /// False once either end has closed the connection.
        var isOpen: Bool {
            openFlag.load(ordering: .relaxed)
        }

        /// Sends `reply`, then closes the connection unless it is `opened` for a request that waits.
        func reply(_ reply: Reply) {
            guard let socket else { return }
            socket.queue.async { socket.send(reply, to: self) }
        }
    }
}

extension ControlSocket.Reply {
    var line: Data {
        struct Wire: Encodable {
            let v = ControlSocket.version
            let reply: String
            var error: String?
            var message: String?
        }
        let wire = switch self {
        case .opened: Wire(reply: "opened")
        case .closed: Wire(reply: "closed")
        case .refused(let failure, let message): Wire(reply: "error", error: failure.rawValue, message: message)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Strings and a number always encode.
        return try! encoder.encode(wire) + Data("\n".utf8)
    }
}
