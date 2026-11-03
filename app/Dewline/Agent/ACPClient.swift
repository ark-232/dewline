import Foundation
import os

/// A JSON value as the Agent Client Protocol sends it.
enum JSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSON].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: JSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .number(let number) where number == number.rounded() && abs(number) < 1e15: try value.encode(Int(number))
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var int: Int? {
        if case .number(let number) = self, number == number.rounded() { Int(number) } else { nil }
    }

    var bool: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    var array: [JSON]? {
        if case .array(let array) = self { array } else { nil }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements) { $1 })
    }
}

/// One agent process, spoken to in JSON-RPC 2.0 over its stdin and stdout, one message per line
/// (agentclientprotocol.com). Requests the agent sends go to `answer`, notifications to `notified`; stderr goes to the
/// log only.
@MainActor
final class ACPClient {
    /// A JSON-RPC error, sent or received.
    struct Failure: Error, Equatable {
        let code: Int
        let message: String

        static func invalid(_ message: String) -> Failure { Failure(code: -32602, message: message) }
        static let notFound = Failure(code: -32601, message: "Method not found")
        /// The process ended before it answered.
        static let ended = Failure(code: -32099, message: "The agent stopped")
    }

    var notified: (String, JSON) -> Void = { _, _ in }
    var answer: (String, JSON) async throws(Failure) -> JSON = { _, _ throws(Failure) in throw .notFound }
    /// The process ended on its own, with its status.
    var ended: (Int32) -> Void = { _ in }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<JSON, any Error>] = [:]
    private var stopping = false
    private nonisolated static let log = Logger(subsystem: "dev.arkwerx.dewline", category: "agent")

    init(executable: URL, arguments: [String], environment: [String: String], folder: URL) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = folder
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        // A write after the agent quits fails instead of raising SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Self.log.info("agent: \(String(decoding: data, as: UTF8.self), privacy: .private)")
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated(status) } }
        }
        try process.run()
    }

    /// Ends the process; nothing more arrives from it.
    func stop() {
        stopping = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        fail(.ended)
    }

    func request(_ method: String, _ params: JSON) async throws -> JSON {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            if !send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]) {
                waiting[id] = nil
                continuation.resume(throwing: Failure.ended)
            }
        }
    }

    func notify(_ method: String, _ params: JSON) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    @discardableResult
    private func send(_ message: JSON) -> Bool {
        guard !stopping, process.isRunning, var data = try? JSONEncoder().encode(message) else { return false }
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func received(_ data: Data) {
        guard !stopping else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard line.contains(where: { $0 != 0x20 && $0 != 0x0D }) else { continue }
            guard let message = try? JSONDecoder().decode(JSON.self, from: Data(line)) else {
                Self.log.error("The agent sent a line that is not JSON")
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: JSON) {
        let id = message["id"]
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            guard let id, id != .null else { return notified(method, params) }
            Task {
                do throws(Failure) {
                    let result = try await answer(method, params)
                    send(["jsonrpc": "2.0", "id": id, "result": result])
                } catch {
                    send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]])
                }
            }
        } else if let id = id?.int, let continuation = waiting.removeValue(forKey: id) {
            if let error = message["error"] {
                continuation.resume(throwing: Failure(code: error["code"]?.int ?? -32603, message: error["message"]?.string ?? "Error"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        }
    }

    private func terminated(_ status: Int32) {
        fail(.ended)
        guard !stopping else { return }
        stopping = true
        ended(status)
    }

    private func fail(_ failure: Failure) {
        let pending = waiting
        waiting = [:]
        for continuation in pending.values { continuation.resume(throwing: failure) }
    }
}
