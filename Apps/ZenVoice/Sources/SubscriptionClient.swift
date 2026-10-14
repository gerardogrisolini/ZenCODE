import Foundation
import Darwin

@MainActor protocol SubscriptionSignaling: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    var onDelegation: ((String, String) -> Void)? { get set }
    func start(credentials: SubscriptionCredentials) async throws
    func open(sdp: String, projects: [String], desktopEnabled: Bool) async throws -> String
    func result(id: String, text: String)
    func speak(_ text: String)
    func stop() async
}
extension VoiceBridgeClient: SubscriptionSignaling {}

/// Auth/control remain in VoiceBridgeClient; the media component only sees SDP.
@MainActor final class SubscriptionClient {
    private var media: (any SubscriptionMedia)?
    private var bridge: (any SubscriptionSignaling)?
    private let makeMedia: @MainActor () -> any SubscriptionMedia
    private let makeBridge: @MainActor () -> any SubscriptionSignaling
    private let startupTimeout: Duration
    private let shutdownTimeout: Duration
    private var startup: Task<Void, Never>?
    private var startupDeadline: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var mediaReady = false
    private var epoch = UUID()
    private var authorized = false
    private var gate = SubscriptionDelegationGate()
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onTool: ((String, JSON) async -> String)?

    init(makeMedia: @escaping @MainActor () -> any SubscriptionMedia = { NativeWebRTCMedia() },
         makeBridge: @escaping @MainActor () -> any SubscriptionSignaling = { VoiceBridgeClient() },
         startupTimeout: Duration = .seconds(40), shutdownTimeout: Duration = .seconds(10)) {
        self.makeMedia = makeMedia; self.makeBridge = makeBridge
        self.startupTimeout = startupTimeout; self.shutdownTimeout = shutdownTimeout
    }

    // VoiceModel calls this only after Attiva, cloud consent and macOS mic permission.
    func connect(credentials: SubscriptionCredentials, projects: [String], desktopEnabled: Bool = false) {
        guard media == nil, bridge == nil, shutdownTask == nil else { return }
        epoch = UUID(); let token = epoch; authorized = true; gate = .init(); mediaReady = false
        startupDeadline = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.startupTimeout) } catch { return }
            guard self.epoch == token, self.authorized, !self.mediaReady else { return }
            self.fail("Tempo massimo di avvio WebRTC superato; riattiva manualmente.", epoch: token)
        }
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try self.check(token)
                let bridge = self.makeBridge(); self.bridge = bridge
                bridge.onFailure = { [weak self] message in self?.fail(message, epoch: token) }
                bridge.onDelegation = { [weak self, weak bridge] id, text in
                    guard let self, let bridge, self.epoch == token, self.authorized else { return }
                    if self.gate.hasSeen(id) { return }
                    guard let arguments = self.gate.accept(id: id, text: text, projects: projects, desktopEnabled: desktopEnabled) else { bridge.result(id: id, text: SubscriptionDelegationGate.rejectionMessage(text: text)); return }
                    Task { [weak self] in
                        guard let self, self.epoch == token, self.authorized else { return }
                        let result = await self.onTool?(id, arguments) ?? "Richiesta rifiutata"
                        guard self.epoch == token, self.authorized else { return }
                        bridge.result(id: id, text: result)
                    }
                }
                try await bridge.start(credentials: credentials)
                try self.check(token)
                let media = self.makeMedia(); self.media = media
                media.onFailure = { [weak self] message in self?.fail(message, epoch: token) }
                let offer = try await media.makeOffer()
                try self.check(token)
                guard offer.utf8.count <= 65_536 else { throw VoiceError.overflow }
                let answer = try await bridge.open(sdp: offer, projects: projects, desktopEnabled: desktopEnabled)
                try self.check(token)
                guard SubscriptionSDPPolicy.accepts(answer) else { throw VoiceError.invalid("Candidati WebRTC non pubblici o SDP non valido: sessione chiusa.") }
                try await media.applyAnswer(answer)
                try self.check(token)
                try await media.waitUntilReady()
                try self.check(token)
                self.mediaReady = true; self.startupDeadline?.cancel(); self.startupDeadline = nil
                self.onReady?()
            } catch {
                self.fail((error as? VoiceError)?.localizedDescription ?? "Connessione audio subscription interrotta. Verifica microfono/rete e riattiva; nessun fallback API.", epoch: token)
            }
        }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard authorized, epoch == token else { throw VoiceError.disconnected }
    }
    private func fail(_ message: String, epoch token: UUID) {
        guard epoch == token, authorized else { return }
        stopMedia()
        // Cleanup is owned here too: callers are not required to react to onFailure.
        _ = beginShutdown()
        onFailure?(message)
    }
    func announce(_ text: String) { if authorized { bridge?.speak(text) } }
    func stopMedia() {
        authorized = false; epoch = UUID(); startup?.cancel(); startup = nil
        startupDeadline?.cancel(); startupDeadline = nil; mediaReady = false
        media?.stopMedia()
    }
    @MainActor private final class Completion { var native = false, transport = false }
    private func beginShutdown() -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        let media = self.media, bridge = self.bridge
        let timeout = shutdownTimeout
        let task = Task { @MainActor [weak self] in
            // Start both cleanups before awaiting either. A hung native delegate or
            // transport cannot hold MainActor or the app's shutdown indefinitely.
            let completion = Completion()
            Task { @MainActor in await media?.shutdown(); completion.native = true }
            Task { @MainActor in await bridge?.stop(); completion.transport = true }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while !(completion.native && completion.transport), ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            self?.media = nil; self?.bridge = nil; self?.shutdownTask = nil
        }
        shutdownTask = task
        return task
    }
    func stop() async {
        stopMedia()
        await beginShutdown().value
    }
}

/// Prevent a provider answer from directing ICE to local services or adding video.
enum SubscriptionSDPPolicy {
    static func publicAddress(_ address: String) -> Bool {
        let p = address.split(separator: ".")
        if p.count == 4, p.allSatisfy({ UInt8($0) != nil }) {
            let a = p.map { Int($0)! }
            if a[0] == 0 || a[0] == 10 || a[0] == 127 || a[0] >= 224 { return false }
            if a[0] == 100 && (64...127).contains(a[1]) || a[0] == 169 && a[1] == 254 || a[0] == 172 && (16...31).contains(a[1]) { return false }
            if a[0] == 192 && (a[1] == 168 || a[1] == 0) || a[0] == 198 && (a[1] == 18 || a[1] == 19 || a[1] == 51 && a[2] == 100) || a[0] == 203 && a[1] == 0 && a[2] == 113 { return false }
            return true
        }
        var value = in6_addr(); guard inet_pton(AF_INET6, address, &value) == 1 else { return false }
        let bytes = withUnsafeBytes(of: value) { Array($0) }
        return bytes[0] & 0xE0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 1 && bytes[2] == 0x0D && bytes[3] == 0xB8)
    }
    static func accepts(_ sdp: String) -> Bool {
        guard sdp.utf8.count <= 65_536, sdp.hasPrefix("v=0"), !sdp.contains("\0"), sdp.contains("a=fingerprint:") else { return false }
        var count = 0, audio = 0, application = 0
        for line in sdp.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("m=") {
                let kind = line.split(separator: " ").first
                if kind == "m=audio" { audio += 1 }
                else if kind == "m=application" { application += 1 }
                else { return false }
                guard audio <= 1, application <= 1 else { return false }
            } else if line.hasPrefix("a=candidate:") {
                let f = line.split(whereSeparator: \.isWhitespace)
                guard f.count >= 8, ["udp", "tcp"].contains(f[2].lowercased()), publicAddress(String(f[4])), let port = Int(f[5]), (1...65535).contains(port), f[6] == "typ" else { return false }
                count += 1; if count > 32 { return false }
            } else if line.hasPrefix("c=IN ") {
                let f = line.split(separator: " "); guard f.count == 3 else { return false }
                guard f[2] == "0.0.0.0" || f[2] == "::" || publicAddress(String(f[2])) else { return false }
            }
        }
        return count > 0 && audio == 1
    }
}
