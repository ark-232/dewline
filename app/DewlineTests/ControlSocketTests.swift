import AppKit
import Testing
@testable import Dewline

/// Each test listens on its own socket in a new temporary folder. None touches the app's socket, shows a window or
/// gives a document a file URL (which would write the recent files to user defaults).
struct ControlSocketTests {
    @Test func opensAValidRequestAndClosesTheConnection() async throws {
        let listening = try await Listening()
        defer { listening.finish() }
        let file = try listening.file("plan.md").path
        let client = try Client(listening.socket.path)
        client.send(#"{"v":1,"op":"open","path":"\#(file)","line":3,"col":2,"later":true}"# + "\n")
        #expect(client.line() == #"{"reply":"opened","v":1}"#)
        #expect(client.line() == nil)
        #expect(await listening.received.requests == [ControlSocket.Open(path: file, line: 3, column: 2, wait: false)])
    }

    @Test func aWaitingRequestHearsClosedWhenItsDocumentCloses() async throws {
        let listening = try await Listening()
        defer { listening.finish() }
        let file = try listening.file("plan.md").path
        try await MainActor.run {
            let document = MarkdownDocument()
            try document.read(from: Data("# Plan\n".utf8), ofType: "net.daringfireball.markdown")
            document.makeWindowControllers()
            listening.received.document = document
        }
        let client = try Client(listening.socket.path)
        client.send(#"{"v":1,"op":"open","path":"\#(file)","wait":true}"# + "\n")
        #expect(client.line() == #"{"reply":"opened","v":1}"#)
        await MainActor.run { listening.received.document?.windowControllers.first?.window?.performClose(nil) }
        #expect(client.line() == #"{"reply":"closed","v":1}"#)
        #expect(client.line() == nil)
    }

    @Test func refusesMalformedRequests() async throws {
        let listening = try await Listening()
        defer { listening.finish() }
        let file = try listening.file("plan.md").path
        let refusals = [
            "not json": "malformed",
            #"["open"]"#: "malformed",
            #"{"v":1,"op":"open"}"#: "malformed",
            #"{"v":"1","op":"open","path":"\#(file)"}"#: "malformed",
            #"{"v":1,"op":"open","path":"\#(file)","wait":"yes"}"#: "malformed",
            #"{"v":1,"op":"open","path":"\#(file)","line":0}"#: "malformed",
            #"{"v":1,"op":"open","path":"\#(file)","col":3}"#: "malformed",
            #"{"v":1,"op":"open","path":"\#(file)\u0000.md"}"#: "malformed",
            String(repeating: "[", count: 15_000): "malformed",
            #"{"v":1,"op":"open","path":"\#(file)"}"# + "\n" + #"{"v":1,"op":"open","path":"\#(file)"}"#: "malformed",
            #"{"v":2,"op":"open","path":"\#(file)"}"#: "version",
            #"{"v":1,"op":"notify","path":"\#(file)"}"#: "unknown_op",
        ]
        for (request, error) in refusals {
            let client = try Client(listening.socket.path)
            client.send(request + "\n")
            #expect(client.line() == #"{"error":"\#(error)","reply":"error","v":1}"#, "\(request.prefix(80))")
            #expect(client.line() == nil)
        }
        #expect(await listening.received.requests.isEmpty)
    }

    @Test func refusesOversizedRequests() async throws {
        let listening = try await Listening()
        defer { listening.finish() }
        let long = #"{"v":1,"op":"open","path":"/\#(String(repeating: "a", count: 20_000))"}"# + "\n"
        for request in [String(repeating: "x", count: ControlSocket.maxRequest), long] {
            let client = try Client(listening.socket.path)
            client.send(request)
            #expect(client.line() == #"{"error":"too_long","reply":"error","v":1}"#)
            #expect(client.line() == nil)
        }
        #expect(await listening.received.requests.isEmpty)
    }

    @Test func refusesAnythingButAnExistingRegularFileByAbsolutePath() async throws {
        let listening = try await Listening()
        defer { listening.finish() }
        let folder = listening.folder.path
        #expect(mkfifo(folder + "/pipe", 0o600) == 0)
        let refusals = [
            "plan.md": "not_absolute",
            "~/plan.md": "not_absolute",
            folder + "/missing.md": "not_found",
            folder: "not_a_file",
            folder + "/pipe": "not_a_file",
            listening.socket.path: "not_a_file",
            "/dev/null": "not_a_file",
        ]
        for (path, error) in refusals {
            let client = try Client(listening.socket.path)
            client.send(#"{"v":1,"op":"open","path":"\#(path)"}"# + "\n")
            #expect(client.line() == #"{"error":"\#(error)","reply":"error","v":1}"#, "\(path)")
        }
        #expect(await listening.received.requests.isEmpty)
    }

    @Test func refusesOtherUsers() async throws {
        // Another uid can't be had without root, so this socket admits one that isn't this user's.
        let listening = try await Listening(uid: geteuid() + 1)
        defer { listening.finish() }
        let client = try Client(listening.socket.path)
        client.send(#"{"v":1,"op":"open","path":"\#(try listening.file("plan.md").path)"}"# + "\n")
        #expect(client.line() == nil)
        #expect(await listening.received.requests.isEmpty)
    }

    @Test func dropsAConnectionThatSendsNothing() async throws {
        let listening = try await Listening()
        defer { listening.finish() }
        let client = try Client(listening.socket.path, timeout: 5)
        let start = ContinuousClock.now
        #expect(client.line() == nil)
        let waited = ContinuousClock.now - start
        #expect(waited > .seconds(1.5) && waited < .seconds(4), "\(waited)")
    }

    @Test func theSocketIsPrivateAndStaysWithTheAppThatHasIt() async throws {
        let listening = try await Listening()
        defer { listening.finish() }
        var info = stat()
        #expect(lstat(listening.folder.appending(path: "run").path, &info) == 0 && info.st_mode & 0o7777 == 0o700)
        #expect(lstat(listening.socket.path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK && info.st_mode & 0o7777 == 0o600)
        let second = ControlSocket(path: listening.socket.path) { _, connection in connection.reply(.opened) }
        #expect(throws: ControlSocket.StartError.inUse) { try second.start() }
        let client = try Client(listening.socket.path)
        client.send(#"{"v":1,"op":"open","path":"\#(try listening.file("plan.md").path)"}"# + "\n")
        #expect(client.line() == #"{"reply":"opened","v":1}"#)
        listening.socket.stop()
        #expect(lstat(listening.socket.path, &info) == -1 && errno == ENOENT)
        // A folder someone opened up is closed again before the socket goes in.
        let open = listening.folder.appending(path: "open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let third = ControlSocket(path: open.appending(path: "control.sock").path) { _, connection in connection.reply(.opened) }
        try third.start()
        defer { third.stop() }
        #expect(lstat(open.path, &info) == 0 && info.st_mode & 0o7777 == 0o700)
    }

    /// The command embedded in this build, talking to the app's side of the socket.
    @Test func theDewlineCommandOpensAndWaitsUntilTheFileCloses() async throws {
        let listening = try await Listening()
        defer { listening.finish() }
        let file = try listening.file("COMMIT_EDITMSG")
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/dewline")
        process.arguments = ["open", "--wait", file.path + ":3:2"]
        process.environment = ["DEWLINE_SOCKET": listening.socket.path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let request = try await listening.nextRequest()
        let real = try #require(realpath(file.path, nil))
        defer { free(real) }
        #expect(request == ControlSocket.Open(path: String(cString: real), line: 3, column: 2, wait: true))
        try await Task.sleep(for: .milliseconds(300))
        #expect(process.isRunning)
        await listening.received.connections.first?.reply(.closed)
        for _ in 0..<50 where process.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!process.isRunning && process.terminationStatus == 0)
    }
}

@MainActor
private final class Received {
    var requests: [ControlSocket.Open] = []
    var connections: [ControlSocket.Connection] = []
    /// When set, waiting requests are answered when it closes.
    var document: MarkdownDocument?
}

/// A started socket in a new folder whose handler records each request and answers `opened`.
private struct Listening {
    let folder: URL
    let socket: ControlSocket
    let received: Received

    init(uid: uid_t = geteuid()) async throws {
        // Short, because a socket path holds at most 103 bytes.
        folder = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString.prefix(8))")
        let received = await Received()
        socket = ControlSocket(path: folder.appending(path: "run/control.sock").path, uid: uid) { request, connection in
            received.requests.append(request)
            received.connections.append(connection)
            if request.wait { received.document?.answerWhenClosed(connection) }
            connection.reply(.opened)
        }
        self.received = received
        try socket.start()
    }

    func file(_ name: String) throws -> URL {
        let url = folder.appending(path: name)
        try Data("# Plan\n\nShip it.\n".utf8).write(to: url)
        return url
    }

    func nextRequest() async throws -> ControlSocket.Open {
        for _ in 0..<50 {
            if let request = await received.requests.first { return request }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }

    func finish() {
        socket.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A blocking client of a socket; a read gives up after `timeout` seconds.
private final class Client {
    private let fd = socket(AF_UNIX, SOCK_STREAM, 0)

    init(_ path: String, timeout: Int = 2) throws {
        var address = try #require(ControlSocket.address(of: path))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        var on: Int32 = 1
        #expect(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size)) == 0)
        #expect(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0)
    }

    deinit {
        close(fd)
    }

    /// Writes what the server takes; it may close early on a request it refuses.
    func send(_ text: String) {
        _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The next line without its newline, or nil once the server closed the connection or the read timed out.
    func line() -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return nil
    }
}
