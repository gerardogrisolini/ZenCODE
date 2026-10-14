import Foundation
import Testing
@preconcurrency import WebRTC

private let nativeFixtureSDP = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=fingerprint:sha-256 fixture\r\na=candidate:1 1 udp 1 8.8.8.8 9000 typ host\r\n"

/// Entirely in-memory: no RTC factory, audio device, URLSession or socket.
private final class FakeNativeMediaDriver: NativeMediaDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (UUID, NativeMediaEvent) -> Void)?
    private var token: UUID?
    private var starts = 0, answers = 0, stops = 0, playback = 0
    private var closeCallback: (@Sendable () -> Void)?
    let provideOffer: Bool, provideAnswer: Bool, automaticReadiness: Bool, finishClose: Bool
    init(offer: Bool = true, answer: Bool = true, ready: Bool = false, close: Bool = true) {
        provideOffer = offer; provideAnswer = answer; automaticReadiness = ready; finishClose = close
    }
    var counts: (starts: Int, answers: Int, stops: Int, playback: Int) {
        lock.withLock { (starts, answers, stops, playback) }
    }
    func start(epoch: UUID, emit: @escaping @Sendable (UUID, NativeMediaEvent) -> Void) {
        lock.withLock { token = epoch; callback = emit; starts += 1 }
        if provideOffer { emit(epoch, .offer(nativeFixtureSDP)) }
    }
    func answer(_ sdp: String, epoch: UUID) {
        lock.withLock { answers += 1 }
        if provideAnswer { send(.answerApplied) }
        if automaticReadiness { send(.peerConnected(true)); send(.channelOpen(true)); send(.remoteAudio(true)) }
    }
    func enablePlayback(epoch: UUID) { lock.withLock { playback += 1 } }
    func stop(completion: @escaping @Sendable () -> Void) {
        lock.withLock { stops += 1; closeCallback = completion }
        if finishClose { completion() }
    }
    func finishShutdown() { lock.withLock { closeCallback }?() }
    func send(_ event: NativeMediaEvent, stale: Bool = false) {
        let snapshot = lock.withLock { (token, callback) }
        if let token = snapshot.0 { snapshot.1?(stale ? UUID() : token, event) }
    }
}

@MainActor private func waitForNativeTest(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor struct NativeWebRTCMediaTests {
    private var shortDeadlines: NativeWebRTCMedia.Deadlines {
        .init(offer: .milliseconds(40), answer: .milliseconds(40), readiness: .milliseconds(40), shutdown: .milliseconds(40))
    }
    @Test func onlyNegotiatedReceivingAudioCanBecomeReady() {
        // Enum values only: no RTC factory, peer or audio device is constructed.
        let receiving: [RTCRtpTransceiverDirection] = [.sendRecv, .recvOnly]
        for direction in receiving {
            #expect(StaselMediaDriver.receivesAudio(direction: direction, stopped: false, trackIsLive: true))
            #expect(!StaselMediaDriver.receivesAudio(direction: direction, stopped: true, trackIsLive: true))
            #expect(!StaselMediaDriver.receivesAudio(direction: direction, stopped: false, trackIsLive: false))
        }
        let notReceiving: [RTCRtpTransceiverDirection?] = [nil, .sendOnly, .inactive, .stopped]
        for direction in notReceiving {
            #expect(!StaselMediaDriver.receivesAudio(direction: direction, stopped: false, trackIsLive: true))
        }
    }
    @Test func constructionDoesNotStartDevicesAndStopIsIdempotent() async {
        let driver = FakeNativeMediaDriver()
        let media = NativeWebRTCMedia(driver: driver)
        #expect(driver.counts.starts == 0)
        media.stopMedia(); media.stopMedia()
        await media.shutdown()
        #expect(driver.counts.starts == 0)
        #expect(driver.counts.stops == 1)
    }
    @Test func readinessNeedsConnectedChannelAndRemoteAudio() async throws {
        let driver = FakeNativeMediaDriver()
        let media = NativeWebRTCMedia(driver: driver)
        #expect(try await media.makeOffer() == nativeFixtureSDP)
        try await media.applyAnswer(nativeFixtureSDP)
        var ready = false
        let pending = Task { try await media.waitUntilReady(); ready = true }
        driver.send(.peerConnected(true)); driver.send(.channelOpen(true))
        try await Task.sleep(for: .milliseconds(25))
        #expect(!ready); #expect(driver.counts.playback == 0)
        driver.send(.remoteAudio(true))
        try await pending.value
        #expect(ready); #expect(driver.counts.playback == 1)
        await media.shutdown()
        #expect(driver.counts.stops == 1)
    }
    @Test func offerDeadlineClosesWithoutNativeCompletion() async {
        let driver = FakeNativeMediaDriver(offer: false)
        let media = NativeWebRTCMedia(driver: driver, deadlines: shortDeadlines)
        await #expect(throws: VoiceError.self) { _ = try await media.makeOffer() }
        #expect(driver.counts.stops == 1)
    }
    @Test func answerDeadlineClosesWithoutNativeCompletion() async throws {
        let driver = FakeNativeMediaDriver(answer: false)
        let media = NativeWebRTCMedia(driver: driver, deadlines: shortDeadlines)
        _ = try await media.makeOffer()
        await #expect(throws: VoiceError.self) { try await media.applyAnswer(nativeFixtureSDP) }
        #expect(driver.counts.answers == 1); #expect(driver.counts.stops == 1)
    }
    @Test func readinessDeadlineClosesPeerWithoutRemoteTrack() async throws {
        let driver = FakeNativeMediaDriver()
        let media = NativeWebRTCMedia(driver: driver, deadlines: shortDeadlines)
        _ = try await media.makeOffer(); try await media.applyAnswer(nativeFixtureSDP)
        driver.send(.peerConnected(true)); driver.send(.channelOpen(true))
        await #expect(throws: VoiceError.self) { try await media.waitUntilReady() }
        #expect(driver.counts.playback == 0); #expect(driver.counts.stops == 1)
    }
    @Test func cancellationDuringOfferClosesImmediately() async throws {
        let driver = FakeNativeMediaDriver(offer: false)
        let media = NativeWebRTCMedia(driver: driver)
        let pending = Task { try await media.makeOffer() }
        try await waitForNativeTest { driver.counts.starts == 1 }
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(driver.counts.stops == 1)
    }
    @Test func stopDuringAnswerFencesLateCallbacks() async throws {
        let driver = FakeNativeMediaDriver(answer: false)
        let media = NativeWebRTCMedia(driver: driver)
        var failures = 0
        media.onFailure = { _ in failures += 1 }
        _ = try await media.makeOffer()
        let pending = Task { try await media.applyAnswer(nativeFixtureSDP) }
        try await waitForNativeTest { driver.counts.answers == 1 }
        media.stopMedia()
        driver.send(.answerApplied); driver.send(.peerConnected(true)); driver.send(.channelOpen(true)); driver.send(.remoteAudio(true)); driver.send(.failed)
        await #expect(throws: VoiceError.self) { try await pending.value }
        #expect(driver.counts.stops == 1); #expect(driver.counts.playback == 0); #expect(failures == 0)
    }
    @Test func foreignEpochCannotFailOrReadyCurrentSession() async throws {
        let driver = FakeNativeMediaDriver()
        let media = NativeWebRTCMedia(driver: driver, deadlines: shortDeadlines)
        var failures = 0
        media.onFailure = { _ in failures += 1 }
        _ = try await media.makeOffer(); try await media.applyAnswer(nativeFixtureSDP)
        driver.send(.failed, stale: true)
        driver.send(.peerConnected(true), stale: true); driver.send(.channelOpen(true), stale: true); driver.send(.remoteAudio(true), stale: true)
        await #expect(throws: VoiceError.self) { try await media.waitUntilReady() }
        #expect(failures == 0); #expect(driver.counts.playback == 0)
    }
    @Test func shutdownDoesNotWaitForeverForDriver() async throws {
        let driver = FakeNativeMediaDriver(close: false)
        let media = NativeWebRTCMedia(driver: driver, deadlines: shortDeadlines)
        _ = try await media.makeOffer()
        let start = ContinuousClock.now
        await media.shutdown()
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(driver.counts.stops == 1)
        driver.finishShutdown()
    }
    @Test func unsafeAnswerNeverReachesNativeDriver() async throws {
        let driver = FakeNativeMediaDriver()
        let media = NativeWebRTCMedia(driver: driver)
        _ = try await media.makeOffer()
        await #expect(throws: VoiceError.self) {
            try await media.applyAnswer(nativeFixtureSDP.replacingOccurrences(of: "8.8.8.8", with: "127.0.0.1"))
        }
        #expect(driver.counts.answers == 0); #expect(driver.counts.stops == 1)
    }
    @Test func nativeFailureStopsBeforeNotifyingCaller() async throws {
        let driver = FakeNativeMediaDriver()
        let media = NativeWebRTCMedia(driver: driver)
        var stoppedOnFailure = false
        media.onFailure = { _ in stoppedOnFailure = driver.counts.stops == 1 }
        _ = try await media.makeOffer()
        driver.send(.failed)
        try await waitForNativeTest { stoppedOnFailure }
        #expect(driver.counts.stops == 1)
    }
    @Test func audioOnlyPublicSDPPolicy() {
        #expect(SubscriptionSDPPolicy.accepts(nativeFixtureSDP))
        for suffix in ["m=video 9 UDP/TLS/RTP/SAVPF 96\r\n", "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n", "c=IN IP4 10.0.0.1\r\n"] {
            #expect(!SubscriptionSDPPolicy.accepts(nativeFixtureSDP + suffix))
        }
        #expect(!SubscriptionSDPPolicy.accepts(nativeFixtureSDP.replacingOccurrences(of: "8.8.8.8", with: "10.0.0.1")))
        #expect(!SubscriptionSDPPolicy.accepts(nativeFixtureSDP.replacingOccurrences(of: "8.8.8.8", with: "peer.local")))
    }
}

@MainActor private final class FakeSubscriptionSignaling: SubscriptionSignaling {
    var onFailure: ((String) -> Void)?
    var onDelegation: ((String, String) -> Void)?
    var rejectStart = false, holdOpen = false, holdStop = false
    var starts = 0, opens = 0, stops = 0
    func start(credentials: SubscriptionCredentials) async throws {
        starts += 1
        if rejectStart { throw VoiceError.disconnected }
    }
    func open(sdp: String, projects: [String], desktopEnabled: Bool) async throws -> String {
        opens += 1
        // Deliberately ignore task cancellation to simulate a late native/provider callback.
        while holdOpen { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
        return nativeFixtureSDP
    }
    func result(id: String, text: String) {}
    func speak(_ text: String) {}
    func stop() async {
        stops += 1
        while holdStop { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
    }
}

@MainActor struct NativeSubscriptionLifecycleTests {
    private var credentials: SubscriptionCredentials {
        .init(accessToken: "offline-fixture", accountID: "offline", expiresAt: .distantFuture)
    }
    @Test func invalidLoginCannotConstructMedia() async throws {
        let bridge = FakeSubscriptionSignaling(); bridge.rejectStart = true
        let driver = FakeNativeMediaDriver()
        var madeMedia = 0, failures = 0
        let client = SubscriptionClient(makeMedia: { madeMedia += 1; return NativeWebRTCMedia(driver: driver) }, makeBridge: { bridge })
        client.onFailure = { _ in failures += 1 }
        client.connect(credentials: credentials, projects: [])
        try await waitForNativeTest { failures == 1 }
        #expect(madeMedia == 0); #expect(driver.counts.starts == 0)
        await client.stop()
    }
    @Test func fullStartupUsesOnlyInjectedOfflineMediaAndSignaling() async throws {
        let bridge = FakeSubscriptionSignaling(), driver = FakeNativeMediaDriver(ready: true)
        let client = SubscriptionClient(makeMedia: { NativeWebRTCMedia(driver: driver) }, makeBridge: { bridge })
        var ready = 0
        client.onReady = { ready += 1 }
        client.connect(credentials: credentials, projects: [])
        try await waitForNativeTest { ready == 1 }
        #expect(bridge.opens == 1); #expect(driver.counts.playback == 1)
        client.stopMedia()
        #expect(driver.counts.stops == 1)
        await client.stop()
        #expect(bridge.stops == 1)
    }
    @Test func stopDuringHTTPDoesNotWaitAndLateAnswerCannotRestartMedia() async throws {
        let bridge = FakeSubscriptionSignaling(); bridge.holdOpen = true
        let driver = FakeNativeMediaDriver(ready: true)
        let client = SubscriptionClient(makeMedia: { NativeWebRTCMedia(driver: driver) }, makeBridge: { bridge })
        var ready = 0, failures = 0
        client.onReady = { ready += 1 }; client.onFailure = { _ in failures += 1 }
        client.connect(credentials: credentials, projects: [])
        try await waitForNativeTest { bridge.opens == 1 }
        client.stopMedia()
        #expect(driver.counts.stops == 1)
        bridge.holdOpen = false
        await client.stop()
        #expect(driver.counts.answers == 0); #expect(ready == 0); #expect(failures == 0)
    }
    @Test func globalStartupTimeoutStopsMediaEvenWithHungOffer() async throws {
        let bridge = FakeSubscriptionSignaling(), driver = FakeNativeMediaDriver(offer: false)
        let client = SubscriptionClient(makeMedia: { NativeWebRTCMedia(driver: driver) }, makeBridge: { bridge }, startupTimeout: .milliseconds(40))
        var failures = 0
        client.onFailure = { _ in failures += 1 }
        client.connect(credentials: credentials, projects: [])
        try await waitForNativeTest { failures == 1 }
        #expect(driver.counts.stops == 1); #expect(bridge.opens == 0)
        await client.stop()
    }
    @Test func shutdownDeadlineDoesNotDependOnSignalingCompletion() async throws {
        let bridge = FakeSubscriptionSignaling(); bridge.holdStop = true
        let driver = FakeNativeMediaDriver(ready: true)
        let client = SubscriptionClient(makeMedia: { NativeWebRTCMedia(driver: driver) }, makeBridge: { bridge }, shutdownTimeout: .milliseconds(40))
        var ready = false
        client.onReady = { ready = true }
        client.connect(credentials: credentials, projects: [])
        try await waitForNativeTest { ready }
        let start = ContinuousClock.now
        await client.stop()
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(driver.counts.stops == 1)
        bridge.holdStop = false
    }
}
