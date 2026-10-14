import Foundation
import Dispatch
@preconcurrency import WebRTC

/// Credential-free seam. Tests inject a driver that never constructs an RTC factory.
@MainActor protocol SubscriptionMedia: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func makeOffer() async throws -> String
    func applyAnswer(_ sdp: String) async throws
    func waitUntilReady() async throws
    func stopMedia()
    func shutdown() async
}

enum NativeMediaEvent: Sendable {
    case offer(String), answerApplied, peerConnected(Bool), channelOpen(Bool), remoteAudio(Bool), failed
}

protocol NativeMediaDriver: Sendable {
    func start(epoch: UUID, emit: @escaping @Sendable (UUID, NativeMediaEvent) -> Void)
    func answer(_ sdp: String, epoch: UUID)
    func enablePlayback(epoch: UUID)
    func stop(completion: @escaping @Sendable () -> Void)
}

/// App deadlines do not depend on a native callback, including callbacks that never arrive.
@MainActor final class NativeWebRTCMedia: SubscriptionMedia {
    struct Deadlines: Sendable {
        var offer: Duration = .seconds(8)
        var answer: Duration = .seconds(8)
        var readiness: Duration = .seconds(12)
        var shutdown: Duration = .seconds(2)
    }
    private let driver: any NativeMediaDriver
    private let deadlines: Deadlines
    private var epoch = UUID()
    private var started = false, stopped = false, closed = false, failed = false
    private var offer: String?
    private var answerApplied = false, connected = false, channelOpen = false, remoteAudio = false
    var onFailure: ((String) -> Void)?

    // Constructing this wrapper or the driver does NOT initialize WebRTC/audio/network.
    init(driver: any NativeMediaDriver = StaselMediaDriver(), deadlines: Deadlines = .init()) {
        self.driver = driver; self.deadlines = deadlines
    }

    func makeOffer() async throws -> String {
        guard !started, !stopped else { throw VoiceError.disconnected }
        started = true
        let token = epoch
        driver.start(epoch: token) { [weak self] token, event in
            Task { @MainActor [weak self] in self?.receive(event, epoch: token) }
        }
        do {
            return try await wait(deadlines.offer, epoch: token) { self.offer }
        } catch { stopMedia(); throw error }
    }

    func applyAnswer(_ sdp: String) async throws {
        guard started, !stopped, offer != nil, !answerApplied else { throw VoiceError.disconnected }
        guard SubscriptionSDPPolicy.accepts(sdp) else {
            stopMedia()
            throw VoiceError.invalid("Candidati WebRTC non pubblici o SDP non valido: sessione chiusa.")
        }
        let token = epoch
        driver.answer(sdp, epoch: token)
        do {
            let _: Bool = try await wait(deadlines.answer, epoch: token) { self.answerApplied ? true : nil }
        } catch { stopMedia(); throw error }
    }

    func waitUntilReady() async throws {
        guard answerApplied, !stopped else { throw VoiceError.disconnected }
        let token = epoch
        do {
            let _: Bool = try await wait(deadlines.readiness, epoch: token) {
                self.connected && self.channelOpen && self.remoteAudio ? true : nil
            }
            driver.enablePlayback(epoch: token)
        } catch { stopMedia(); throw error }
        // This is transport/remote-track readiness, never a physical playback receipt.
    }

    private func receive(_ event: NativeMediaEvent, epoch token: UUID) {
        guard token == epoch, started, !stopped else { return }
        switch event {
        case .offer(let value):
            guard value.hasPrefix("v=0"), value.utf8.count <= 65_536 else { fail(); return }
            offer = value
        case .answerApplied: answerApplied = true
        case .peerConnected(let value): connected = value
        case .channelOpen(let value): channelOpen = value
        case .remoteAudio(let value): remoteAudio = value
        case .failed: fail()
        }
    }
    private func fail() {
        failed = true
        stopMedia()
        onFailure?("Connessione audio subscription interrotta. Riattiva manualmente; nessun fallback API.")
    }
    private func wait<T>(_ duration: Duration, epoch token: UUID, value: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while true {
            try Task.checkCancellation()
            guard epoch == token, !stopped, !failed else { throw VoiceError.disconnected }
            if let result = value() { return result }
            guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func stopMedia() {
        guard !stopped else { return }
        stopped = true; epoch = UUID(); offer = nil
        connected = false; channelOpen = false; remoteAudio = false
        // Enqueue disable + close immediately, independently of pending SDP/HTTP work.
        driver.stop { [weak self] in Task { @MainActor [weak self] in self?.closed = true } }
    }
    func shutdown() async {
        stopMedia()
        let deadline = ContinuousClock.now.advanced(by: deadlines.shutdown)
        while !closed, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// All RTC objects and mutable lifecycle state are confined to queue. Delegates only
/// send value snapshots to that queue, never wait for it or MainActor. The sole
/// cross-queue flag is lock-protected, so stop also fences work already enqueued.
final class StaselMediaDriver: NativeMediaDriver, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.zencode.ZenVoice.native-media", qos: .userInitiated)
    private let stopLock = NSLock()
    private var stopRequested = false
    private var epoch: UUID?
    private var emit: (@Sendable (UUID, NativeMediaEvent) -> Void)?
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var localAudio: RTCAudioTrack?
    private var remoteAudio: [RTCAudioTrack] = []
    private var delegate: NativeRTCDelegate?
    private var localDescriptionSet = false, offerDelivered = false, playbackEnabled = false
    private var connectedOnce = false, channelOpenedOnce = false

    private static let initializeSSL: Void = {
        RTCSetMinDebugLogLevel(.none)
        _ = RTCInitializeSSL()
        // Process lifetime: no CleanupSSL while any factory might still be closing.
    }()

    private func active(_ token: UUID) -> Bool {
        epoch == token && !stopLock.withLock { stopRequested }
    }
    func start(epoch token: UUID, emit: @escaping @Sendable (UUID, NativeMediaEvent) -> Void) {
        queue.async { [self] in
            guard epoch == nil, !stopLock.withLock({ stopRequested }) else { return }
            epoch = token; self.emit = emit
            _ = Self.initializeSSL
            // nil video factories; default macOS ADM is AudioDeviceMac (CoreAudio),
            // not RTCAudioSession, the iOS-only manual audio/device API.
            let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
            self.factory = factory
            guard active(token) else { return }
            let delegate = NativeRTCDelegate { [weak self] signal in
                guard let self else { return }
                self.queue.async { [self] in
                    guard active(token) else { return }
                    handle(signal, token: token)
                }
            }
            self.delegate = delegate
            let configuration = RTCConfiguration()
            configuration.iceServers = []
            configuration.sdpSemantics = .unifiedPlan
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: delegate) else {
                fail(token); return
            }
            self.peer = peer
            let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
                "googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"
            ]))
            let track = factory.audioTrack(with: source, trackId: "zenvoice-audio")
            localAudio = track
            guard active(token), peer.add(track, streamIds: ["zenvoice"]) != nil else { fail(token); return }
            let channelConfiguration = RTCDataChannelConfiguration()
            channelConfiguration.isOrdered = true
            channelConfiguration.isNegotiated = false
            guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: channelConfiguration) else {
                fail(token); return
            }
            self.channel = channel; channel.delegate = delegate
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"], optionalConstraints: nil)) { [weak self] description, error in
                // Copy value only; do not transfer Objective-C state between executors.
                let sdp = error == nil ? description?.sdp : nil
                guard let self else { return }
                self.queue.async { [self] in
                    guard active(token), let peer = self.peer else { return }
                    guard let sdp, sdp.utf8.count <= 65_536 else { fail(token); return }
                    peer.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
                        let success = error == nil
                        guard let self else { return }
                        self.queue.async { [self] in
                            guard active(token) else { return }
                            guard success else { fail(token); return }
                            localDescriptionSet = true
                            if self.peer?.iceGatheringState == .complete { deliverOffer(token) }
                            // Preserve the prior bounded gathering window, not an unbounded ICE wait.
                            queue.asyncAfter(deadline: .now() + 2) { [self] in deliverOffer(token) }
                        }
                    }
                }
            }
        }
    }
    private func deliverOffer(_ token: UUID) {
        guard active(token), localDescriptionSet, !offerDelivered else { return }
        guard let sdp = peer?.localDescription?.sdp, sdp.utf8.count <= 65_536 else { fail(token); return }
        offerDelivered = true; send(.offer(sdp), token)
    }
    func answer(_ sdp: String, epoch token: UUID) {
        queue.async { [self] in
            guard active(token), let peer, offerDelivered else { return }
            // Defence in depth: no API can bypass public-address/audio-only policy.
            guard SubscriptionSDPPolicy.accepts(sdp) else { fail(token); return }
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                let success = error == nil
                guard let self else { return }
                self.queue.async { [self] in
                    guard active(token) else { return }
                    guard success else { fail(token); return }
                    refreshTracks(token)
                    send(.answerApplied, token)
                }
            }
        }
    }
    func enablePlayback(epoch token: UUID) {
        queue.async { [self] in
            guard active(token) else { return }
            playbackEnabled = true
            for track in remoteAudio { track.source.volume = 1; track.isEnabled = true }
        }
    }
    private func handle(_ signal: NativeRTCSignal, token: UUID) {
        switch signal {
        case .gatheringComplete: deliverOffer(token)
        case .tracksChanged: refreshTracks(token)
        case .peerState(let state):
            let connected = state == .connected
            send(.peerConnected(connected), token)
            if state == .failed || state == .closed || (connectedOnce && state == .disconnected) { fail(token) }
            if connected { connectedOnce = true }
        case .iceFailed, .unexpectedMedia: fail(token)
        case .channelChanged:
            let state = channel?.readyState
            send(.channelOpen(state == .open), token)
            if state == .open { channelOpenedOnce = true }
            if state == .closed || state == .closing || (channelOpenedOnce && state != .open) { fail(token) }
        }
    }
    /// A Unified Plan receiver exists even when the negotiated direction cannot receive.
    static func receivesAudio(direction: RTCRtpTransceiverDirection?, stopped: Bool, trackIsLive: Bool) -> Bool {
        !stopped && trackIsLive && (direction == .sendRecv || direction == .recvOnly)
    }
    private func refreshTracks(_ token: UUID) {
        guard active(token), let peer else { return }
        var tracks: [RTCAudioTrack] = []
        for transceiver in peer.transceivers {
            guard let track = transceiver.receiver.track else { continue }
            guard let audio = track as? RTCAudioTrack else { track.isEnabled = false; fail(token); return }
            var currentDirection: RTCRtpTransceiverDirection = .inactive
            let direction = transceiver.currentDirection(&currentDirection) ? currentDirection : nil
            guard Self.receivesAudio(direction: direction, stopped: transceiver.isStopped, trackIsLive: audio.readyState == .live) else {
                audio.isEnabled = false; audio.source.volume = 0
                continue
            }
            audio.isEnabled = playbackEnabled
            audio.source.volume = playbackEnabled ? 1 : 0
            tracks.append(audio)
        }
        guard tracks.count <= 1 else { fail(token); return }
        let lost = !remoteAudio.isEmpty && tracks.isEmpty
        remoteAudio = tracks
        send(.remoteAudio(!tracks.isEmpty), token)
        if lost { fail(token) }
    }
    private func send(_ event: NativeMediaEvent, _ token: UUID) {
        guard active(token) else { return }
        emit?(token, event)
    }
    private func fail(_ token: UUID) {
        send(.failed, token)
        stop(completion: {})
    }
    func stop(completion: @escaping @Sendable () -> Void) {
        stopLock.withLock { stopRequested = true }
        queue.async { [self] in
            // Disabling a track silences media; it is NOT an ADM hardware stop.
            // close terminates media/transport; releasing peer + factory tears down ADM.
            localAudio?.isEnabled = false
            for track in remoteAudio { track.isEnabled = false; track.source.volume = 0 }
            for receiver in peer?.receivers ?? [] { receiver.track?.isEnabled = false }
            channel?.delegate = nil; peer?.delegate = nil
            channel?.close(); peer?.close()
            channel = nil; remoteAudio = []; localAudio = nil; peer = nil
            delegate = nil; factory = nil; emit = nil; epoch = nil
            completion()
        }
    }
}

private enum NativeRTCSignal: Sendable {
    case gatheringComplete, tracksChanged, channelChanged, iceFailed, unexpectedMedia
    case peerState(RTCPeerConnectionState)
}

/// Immutable relay, called on libwebrtc threads. Never reads owner/actor state.
private final class NativeRTCDelegate: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    private let emit: @Sendable (NativeRTCSignal) -> Void
    init(emit: @escaping @Sendable (NativeRTCSignal) -> Void) { self.emit = emit }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { emit(.tracksChanged) }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { emit(.tracksChanged) }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed { emit(.iceFailed) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { emit(.gatheringComplete) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.close(); emit(.unexpectedMedia)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        emit(.peerState(newState))
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        // RTC proxy setters are safe on their callback thread. Silence new tracks
        // before the worker evaluates readiness; never move RTC objects to MainActor.
        rtpReceiver.track?.isEnabled = false
        if let audio = rtpReceiver.track as? RTCAudioTrack { audio.source.volume = 0 }
        emit(.tracksChanged)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) { emit(.tracksChanged) }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) { emit(.channelChanged) }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // oai-events is not a second control transport. No payload parsing/logging,
        // transcript retention, commands or credentials pass through the media seam.
    }
}
