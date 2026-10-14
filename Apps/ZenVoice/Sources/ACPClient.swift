import Foundation
import Darwin

/// One process and session per canonical checkout. Pipe ownership is independent of voice lifetime.
@MainActor final class ACPClient {
    let process = Process()
    let instanceID = UUID()
    private let input = Pipe()
    private let output = Pipe()
    private var reader: Task<Void, Never>?
    private var framer = LineFramer()
    private var writer: Task<Void, Never>?
    private var writeQueue: [Data] = []
    private(set) var terminal = false
    private var stopping = false
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private(set) var sessionID = ""
    private(set) var busy = false
    private(set) var summary = "Pronto"
    var permission: ((JSON, JSON) -> Void)?
    var changed: (() -> Void)?

    func start(executable: String, cwd: String) async throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--acp", "--working-directory", cwd]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // Do not propagate app keys, tokens, tracing, or caller-injected provider settings.
        let environment = ProcessInfo.processInfo.environment
        process.environment = Dictionary(uniqueKeysWithValues: ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "SHELL"].compactMap { key in environment[key].map { (key, $0) } })
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let fd = input.fileHandleForWriting.fileDescriptor
        guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw VoiceError.invalid("Impossibile configurare pipe sicure") }
        let readFD = output.fileHandleForReading.fileDescriptor
        let readFlags = fcntl(readFD, F_GETFL)
        guard readFlags != -1, fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK) != -1 else {
            throw VoiceError.invalid("Impossibile configurare pipe sicure")
        }
        try process.run()
        reader = Task { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            do {
                // Read only available bytes; never wait for a full buffer or EOF.
                while !Task.isCancelled {
                    guard let self, !self.terminal else { return }
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
                    if count > 0 {
                        for line in try self.framer.append(Data(buffer.prefix(count))) {
                            guard !Task.isCancelled, !self.terminal else { return }
                            try self.receive(JSON.parse(line))
                        }
                        await Task.yield()
                    } else if count < 0, errno == EINTR {
                        await Task.yield()
                    } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        try await Task.sleep(for: .milliseconds(10))
                    } else {
                        self.fail(VoiceError.disconnected)
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch { self?.fail(error) }
        }
        do {
            let initialized = try await request("initialize", ["protocolVersion": 1, "clientCapabilities": ["audio": false]], seconds: 20)
            guard initialized["protocolVersion"].integer == 1 else { throw VoiceError.invalid("Versione ACP non supportata") }
            let session = try await request("session/new", ["cwd": .string(cwd), "mcpServers": []], seconds: 30)
            guard let id = session["sessionId"].text else { throw VoiceError.invalid("Sessione ACP mancante") }
            sessionID = id
        } catch { shutdown(); throw error }
    }
    func prompt(_ text: String) async throws -> String {
        guard !terminal, !busy, process.isRunning else { throw VoiceError.invalid("Checkout occupato o processo non disponibile") }
        busy = true; summary = "In esecuzione"; changed?()
        defer { busy = false; changed?() }
        _ = try await request("session/prompt", ["sessionId": .string(sessionID), "prompt": [["type": "text", "text": .string(text)]]], seconds: 3600)
        return summary
    }
    func cancel() throws { try notify("session/cancel", ["sessionId": .string(sessionID)]) }
    func respond(id: JSON, option: String?) throws {
        let outcome: JSON = option.map { ["outcome": "selected", "optionId": .string($0)] } ?? ["outcome": "cancelled"]
        try write(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
    }
    private func receive(_ message: JSON) throws {
        guard message["jsonrpc"].text == "2.0" else { throw VoiceError.invalid("Frame ACP non valido") }
        if let method = message["method"].text {
            let params = message["params"]
            if method == "session/request_permission", message["id"] != .null {
                guard params["sessionId"].text == sessionID else { try respond(id: message["id"], option: nil); return }
                permission?(message["id"], params)
            } else if method == "session/update", params["sessionId"].text == sessionID {
                let update = params["update"]
                switch update["sessionUpdate"].text {
                case "agent_message_chunk":
                    if let text = update["content"]["text"].text { summary = String((summary + text).suffix(12_000)) }
                case "tool_call", "tool_call_update":
                    summary = String((update["title"].text ?? "Tool") .prefix(300)) + " · " + (update["status"].text ?? "in corso")
                default: break
                }
                changed?()
            } else if message["id"] != .null {
                try write(["jsonrpc": "2.0", "id": message["id"], "error": ["code": -32601, "message": "Unsupported method"]])
            }
        } else if let id = message["id"].integer, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if message["error"] != .null { continuation.resume(throwing: VoiceError.invalid("Richiesta ACP rifiutata; verifica setup zen nel Terminale")) }
            else { continuation.resume(returning: message["result"]) }
        }
    }
    private func request(_ method: String, _ params: JSON, seconds: UInt64) async throws -> JSON {
        sequence += 1; let id = sequence
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                guard let self, let c = self.pending.removeValue(forKey: id) else { return }
                self.timeouts.removeValue(forKey: id); c.resume(throwing: VoiceError.timeout)
                self.shutdown() // Never release checkout for another prompt while timed-out work might remain alive.
            }
            do { try write(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error); timeouts.removeValue(forKey: id)?.cancel() }
        }
    }
    private func notify(_ method: String, _ params: JSON) throws { try write(["jsonrpc": "2.0", "method": .string(method), "params": params]) }
    private func write(_ value: JSON) throws {
        guard !terminal else { throw VoiceError.disconnected }
        var data = try value.encoded(); data.append(10)
        guard data.count <= 65_536, writeQueue.reduce(0, { $0 + $1.count }) + data.count <= 1_048_576 else { throw VoiceError.overflow }
        writeQueue.append(data)
        guard writer == nil else { return }
        writer = Task { [weak self] in
            guard let self else { return }
            defer { self.writer = nil }
            var deadline = Date().addingTimeInterval(5)
            while !self.writeQueue.isEmpty, !Task.isCancelled {
                let bytes = self.writeQueue[0]
                let count = bytes.withUnsafeBytes { raw in Darwin.write(self.input.fileHandleForWriting.fileDescriptor, raw.baseAddress, raw.count) }
                if count > 0 {
                    self.writeQueue[0].removeFirst(count)
                    if self.writeQueue[0].isEmpty { self.writeQueue.removeFirst() }
                    deadline = Date().addingTimeInterval(5)
                } else if count < 0, errno == EINTR { continue }
                else if count < 0, errno == EAGAIN, Date() < deadline {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                } else { self.fail(VoiceError.disconnected); return }
            }
        }
    }
    private func fail(_ error: Error) {
        guard !terminal else { return }
        terminal = true
        let waits = pending; pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        waits.values.forEach { $0.resume(throwing: error) }
        summary = "Processo terminato o errore ACP"; changed?()
        if !stopping { shutdown() }
    }
    func close() async {
        if !terminal, process.isRunning, !sessionID.isEmpty {
            try? cancel()
            _ = try? await request("session/close", ["sessionId": .string(sessionID)], seconds: 2)
        }
        shutdown()
    }
    func shutdown() {
        guard !stopping else { return }
        stopping = true
        // EOF is the deterministic fallback for transport failure or a non-responsive close.
        writer?.cancel(); writer = nil; writeQueue.removeAll()
        try? input.fileHandleForWriting.close()
        reader?.cancel(); reader = nil
        try? output.fileHandleForReading.close()
        fail(VoiceError.disconnected)
        let child = process
        Task {
            try? await Task.sleep(for: .seconds(2))
            if child.isRunning { child.terminate() }
            try? await Task.sleep(for: .seconds(2))
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}
