import Foundation
import Darwin

/// Dedicated voice IPC process. It cannot request ACP tasks and never receives bearer credentials.
@MainActor final class VoiceBridgeClient {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var reader: Task<Void, Never>?, writer: Task<Void, Never>?
    private var queue: [Data] = []
    private var framer = LineFramer(limit: 131_072)
    private var ready = false, failed = false, stopping = false, closed = false
    private var openID: String?
    private var opening: CheckedContinuation<String, Error>?
    var onFailure: ((String) -> Void)?
    var onDelegation: ((String, String) -> Void)?
    func start(executable: String) async throws {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["--voice-bridge"]
        let env = ProcessInfo.processInfo.environment
        process.environment = Dictionary(uniqueKeysWithValues: ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "SHELL"].compactMap { key in env[key].map { (key, $0) } })
        // Use the same settings file validated by ZenVoice, not a caller-provided support directory.
        process.environment?["ZENCODE_SUPPORT_DIRECTORY"] = ZenCODEConfiguration.directory.path
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw VoiceError.disconnected }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw VoiceError.disconnected }
        try process.run()
        reader = Task { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                guard let self, !self.closed else { return }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(self.output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
                do {
                    if count > 0 { for line in try self.framer.append(Data(buffer.prefix(count))) { try self.receive(JSON.parse(line)) } }
                    else if count == 0 { if !self.stopping { self.fail("bridge_disconnected") }; return }
                    else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw VoiceError.disconnected }
                    try await Task.sleep(for: .milliseconds(10))
                } catch { if !Task.isCancelled { self.fail("bridge_protocol") }; return }
            }
        }
        for _ in 0..<500 {
            if failed { throw VoiceError.disconnected }
            if ready { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VoiceError.timeout
    }
    func open(sdp: String, projects: [String]) async throws -> String {
        guard ready, !failed, !stopping, opening == nil, openID == nil else { throw VoiceError.disconnected }
        let id = UUID().uuidString; openID = id
        return try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            do { try send(["version": 1, "id": .string(id), "command": "open", "sdp": .string(sdp), "projects": .array(projects.map(JSON.string))]) }
            catch { opening = nil; continuation.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.openID == id, self.opening != nil else { return }
                self.fail("bridge_timeout")
            }
        }
    }
    func speak(_ text: String) {
        let bounded = VoiceTextLimit.truncate(text, bytes: 12_000)
        guard !bounded.isEmpty else { return }
        command("speak", text: bounded)
    }
    func result(id: String, text: String) { command("delegationResult", text: VoiceTextLimit.truncate(text, bytes: 12_000), delegation: id) }
    private func command(_ name: String, text: String, delegation: String? = nil) {
        var value: JSON = ["version": 1, "id": .string(UUID().uuidString), "command": .string(name), "text": .string(text)]
        if case .object(var object) = value, let delegation { object["delegationID"] = .string(delegation); value = .object(object) }
        do { try send(value) } catch { fail("bridge_protocol") }
    }
    private func receive(_ event: JSON) throws {
        guard event["version"].integer == 1 else { throw VoiceError.disconnected }
        switch event["type"].text {
        case "ready": ready = true
        case "opened":
            guard event["id"].text == openID, let sdp = event["sdp"].text, sdp.utf8.count <= 65_536, sdp.hasPrefix("v=0"), let opening else { throw VoiceError.disconnected }
            self.opening = nil; opening.resume(returning: sdp)
        case "delegation":
            guard let id = event["id"].text, let text = event["text"].text, id.utf8.count <= 160, text.utf8.count <= 16_000, !stopping else { throw VoiceError.disconnected }
            onDelegation?(id, text)
        case "error": fail(event["code"].text ?? "voice_error")
        case "closed": closed = true; if !stopping { fail("bridge_disconnected") }
        case "session": break
        default: throw VoiceError.disconnected
        }
    }
    private func send(_ event: JSON) throws {
        guard !failed, !closed else { throw VoiceError.disconnected }
        var bytes = try event.encoded(); bytes.append(10)
        guard bytes.count <= 131_072, queue.reduce(0, { $0 + $1.count }) + bytes.count <= 1_048_576 else { throw VoiceError.overflow }
        queue.append(bytes)
        guard writer == nil else { return }
        writer = Task { [weak self] in
            guard let self else { return }; defer { self.writer = nil }
            var deadline = Date().addingTimeInterval(5)
            while !self.queue.isEmpty, !Task.isCancelled {
                let n = self.queue[0].withUnsafeBytes { Darwin.write(self.input.fileHandleForWriting.fileDescriptor, $0.baseAddress, $0.count) }
                if n > 0 { self.queue[0].removeFirst(n); if self.queue[0].isEmpty { self.queue.removeFirst() }; deadline = Date().addingTimeInterval(5) }
                else if n < 0, errno == EINTR { continue }
                else if n < 0, errno == EAGAIN, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
                else { self.fail("bridge_disconnected"); return }
            }
        }
    }
    private func fail(_ code: String) {
        guard !failed else { return }; failed = true
        opening?.resume(throwing: VoiceError.invalid(Self.message(code))); opening = nil
        if !stopping { onFailure?(Self.message(code)) }
    }
    static func message(_ code: String) -> String {
        switch code {
        case "auth_missing": "Login ChatGPT assente: configura zen nel Terminale. Nessun fallback API."
        case "auth_expired", "auth_rejected": "Login ChatGPT da rinnovare nel Terminale; nessun refresh automatico."
        case "access_denied": "Accesso voce subscription negato dal provider (403)."
        case "quota": "Limite o quota subscription: attendi indicazioni del provider."
        default: "Voce subscription interrotta; verifica zen e riattiva manualmente."
        }
    }
    func stop() async {
        guard !stopping else { return }; stopping = true
        opening?.resume(throwing: VoiceError.disconnected); opening = nil
        if !failed && !closed { try? send(["version": 1, "id": .string(UUID().uuidString), "command": "close"]) }
        // EOF also cancels an in-flight create; never rotate auth or replay it.
        for _ in 0..<100 { if queue.isEmpty { break }; try? await Task.sleep(for: .milliseconds(10)) }
        writer?.cancel(); queue.removeAll(); try? input.fileHandleForWriting.close()
        for _ in 0..<2000 { if !process.isRunning { break }; try? await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); try? await Task.sleep(for: .seconds(1)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        reader?.cancel(); reader = nil; try? output.fileHandleForReading.close(); closed = true
    }
}

/// Reject provider-generated free text/unknown actions rather than guessing a project or launching work.
struct SubscriptionDelegationGate {
    private var seen = Set<String>()
    func hasSeen(_ id: String) -> Bool { seen.contains(id) }
    mutating func accept(id: String, text: String, projects: [String]) -> JSON? {
        guard !id.isEmpty, id.utf8.count <= 160, seen.count < 256, seen.insert(id).inserted, text.utf8.count <= 16_000,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let value = try? JSON.parse(Data(text.utf8)), case .object(let object) = value,
              Set(object.keys) == ["action", "project", "prompt"], let action = value["action"].text,
              ["start", "status", "cancel"].contains(action), let project = value["project"].text, projects.contains(project),
              let prompt = value["prompt"].text, action != "start" || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
