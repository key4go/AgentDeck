import Darwin
import Foundation

enum WireValue: Codable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case null, bool(Bool), int(Int), real(Double), string(String), array([Self]), object([String: Self])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: Self...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, Self)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .real(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .real(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> Self {
        if case .object(let value) = self { return value[key] ?? .null }
        return .null
    }

    func contains(_ key: String) -> Bool {
        if case .object(let value) = self { return value[key] != nil }
        return false
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var int: Int? { if case .int(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var array: [Self] { if case .array(let value) = self { value } else { [] } }
    var formatted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    var isID: Bool { string != nil || int != nil }
}

enum ServerEvent: Sendable {
    case notification(String, WireValue)
    case request(WireValue, String, WireValue)
    case disconnected(String)
}

enum ServerFailure: LocalizedError, Sendable {
    case closed, invalidFrame, executable, unavailable, busy
    case timeout(String)
    case rpc(String, Int, String)

    var errorDescription: String? {
        switch self {
        case .closed: "The Codex App Server connection closed."
        case .invalidFrame: "Codex sent an invalid or oversized protocol message."
        case .executable: "Choose an executable Codex CLI file."
        case .unavailable: "That action requires a connected AgentDeck-managed session."
        case .busy: "Wait for the current action to finish."
        case .timeout(let method): "Codex did not answer \(method) before it timed out. Check the chat before retrying."
        case .rpc(let method, let code, let message): "\(method) (\(code)): \(message)"
        }
    }
}

actor AppServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: (method: String, reply: CheckedContinuation<WireValue, any Error>)] = [:]
    private var isOpen = false
    private var didStart = false
    private(set) var serverIdentity = "Version unavailable"
    private var bytes: AsyncStream<Data>.Continuation?
    private let continuation: AsyncStream<ServerEvent>.Continuation
    nonisolated let events: AsyncStream<ServerEvent>
    private let deadline: Duration
    private var socket: LocalWebSocket?
    private let shared: Bool
    private let frameLimit = 8 * 1024 * 1024

    init(deadline: Duration = .seconds(15), shared: Bool = false) {
        self.shared = shared
        self.deadline = deadline
        (events, continuation) = AsyncStream.makeStream()
    }

    func connect(executable: URL) async throws {
        guard !didStart else { throw ServerFailure.busy }
        let resolved = executable.resolvingSymlinksInPath()
        guard resolved.isFileURL, FileManager.default.isExecutableFile(atPath: resolved.path),
              (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ServerFailure.executable
        }
        process.executableURL = resolved
        process.arguments = shared ? ["app-server", "proxy"] : ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let fd = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1,
              fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else {
            throw ServerFailure.closed
        }
        try process.run()
        isOpen = true
        didStart = true

        let handle = output.fileHandleForReading
        let (chunks, bytes) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.bytes = bytes
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                bytes.finish()
            } else if case .dropped = bytes.yield(chunk) {
                handle.readabilityHandler = nil
                bytes.finish()
            }
        }
        Task { [weak self] in
            for await chunk in chunks { await self?.receive(chunk) }
            await self?.finishReading()
        }

        do {
            if shared {
                socket = LocalWebSocket()
                try input.fileHandleForWriting.write(contentsOf: socket!.upgrade)
                let clock = ContinuousClock()
                let until = clock.now + deadline
                while socket?.ready != true {
                    guard isOpen else { throw ServerFailure.closed }
                    guard clock.now < until else { throw ServerFailure.timeout("shared Codex connection") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            let handshake = try await request("initialize", [
                "clientInfo": ["name": "agentdeck", "title": "AgentDeck", "version": "0.6.0"],
                "capabilities": ["experimentalApi": true]
            ])
            guard handshake["platformOs"].string != nil else { throw ServerFailure.invalidFrame }
            serverIdentity = handshake["userAgent"].string ?? "Version unavailable"
            try write(["method": "initialized"])
        } catch {
            close()
            throw error
        }
    }

    func request(_ method: String, _ params: WireValue = [:]) async throws -> WireValue {
        guard isOpen else { throw ServerFailure.closed }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        let timeout = Task { [weak self, deadline] in
            try await Task.sleep(for: deadline)
            await self?.expire(id, method: method)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                pending[id] = (method, reply)
                do {
                    try write(["id": .int(id), "method": .string(method), "params": params])
                } catch {
                    pending.removeValue(forKey: id)?.reply.resume(throwing: error)
                    close()
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func reply(id: WireValue, result: WireValue) throws {
        try write(["id": id, "result": result])
    }

    func reject(id: WireValue) throws {
        try write(["id": id, "error": ["code": -32601, "message": "This request is unavailable in AgentDeck."]])
    }

    func close(_ error: ServerFailure = .closed) {
        guard isOpen else { return }
        isOpen = false
        output.fileHandleForReading.readabilityHandler = nil
        bytes?.finish()
        bytes = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { _ = kill(pid, SIGKILL) }
            }
        }
        for entry in pending.values { entry.reply.resume(throwing: error) }
        pending.removeAll()
        continuation.yield(.disconnected(error.localizedDescription))
        continuation.finish()
    }

    private func finishReading() {
        close(buffer.isEmpty ? .closed : .invalidFrame)
    }

    private func write(_ message: WireValue) throws {
        guard isOpen else { throw ServerFailure.closed }
        var data = try JSONEncoder().encode(message)
        if shared { data = LocalWebSocket.frame(data) }
        else { data.append(0x0a) }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard isOpen else { return }
        if shared {
            do {
                let events = try socket?.receive(data) ?? []
                for event in events {
                    switch event {
                    case .message(let payload):
                        guard let message = try? JSONDecoder().decode(WireValue.self, from: payload), handle(message) else {
                            throw ServerFailure.invalidFrame
                        }
                    case .ping(let payload):
                        try input.fileHandleForWriting.write(contentsOf: LocalWebSocket.frame(payload, opcode: 10))
                    case .closed(let payload):
                        let code = payload.count >= 2 ? Int(payload[payload.startIndex]) * 256 + Int(payload[payload.startIndex + 1]) : 1000
                        let reason = String(decoding: payload.dropFirst(2), as: UTF8.self)
                        close(.rpc("shared Codex connection", code, String(reason.prefix(500))))
                    }
                }
            } catch { close(.invalidFrame) }
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            guard line.count <= frameLimit, let message = try? JSONDecoder().decode(WireValue.self, from: line),
                  handle(message) else {
                close(.invalidFrame)
                return
            }
            buffer.removeSubrange(...newline)
        }
        if buffer.count > frameLimit { close(.invalidFrame) }
    }

    private func handle(_ message: WireValue) -> Bool {
        if let method = message["method"].string {
            guard !message.contains("result"), !message.contains("error") else { return false }
            let id = message["id"]
            if message.contains("id") {
                guard id.isID else { return false }
                continuation.yield(.request(id, method, message["params"]))
            } else {
                continuation.yield(.notification(method, message["params"]))
            }
            return true
        }
        guard let id = message["id"].int else { return false }
        guard let response = pending.removeValue(forKey: id) else { return true }
        if !message.contains("result"), let code = message["error"]["code"].int {
            let detail = String((message["error"]["message"].string ?? "Request failed.").prefix(500))
            response.reply.resume(throwing: ServerFailure.rpc(response.method, code, detail))
        } else if !message.contains("error"), message.contains("result") {
            response.reply.resume(returning: message["result"])
        } else {
            response.reply.resume(throwing: ServerFailure.invalidFrame)
            return false
        }
        return true
    }

    private func expire(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.reply.resume(throwing: ServerFailure.timeout(method))
    }

    private func cancel(_ id: Int) {
        pending.removeValue(forKey: id)?.reply.resume(throwing: CancellationError())
    }
}

protocol CodexClient: Sendable {
    var events: AsyncStream<ServerEvent> { get }
    func connect(executable: URL) async throws
    func request(_ method: String, _ params: WireValue) async throws -> WireValue
    func reply(id: WireValue, result: WireValue) async throws
    func reject(id: WireValue) async throws
    func close(_ error: ServerFailure) async
}

extension AppServer: CodexClient {}
