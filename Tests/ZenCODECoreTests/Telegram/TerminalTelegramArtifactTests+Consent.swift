//
//  TerminalTelegramArtifactTests+Consent.swift
//  ZenCODE
//
//  Explicit-consent tests of the Telegram artifact upload path: single-use
//  offers, fingerprint checks and the stop fences around suspended downloads
//  and uploads, with the gating transports and broker helpers they need.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalTelegramArtifactTests {
    private static var routeLease: TerminalTelegramRouteLease {
        .init(key: .init(chatID: 42, userID: 7, roomID: "test-room"), generation: 1)
    }

    private static func wireFence(epoch: UUID) -> TerminalTelegramWireFence {
        let lease = routeLease
        return TerminalTelegramWireFence(lease: lease, lifecycleEpoch: epoch) { candidate in
            guard candidate == lease else { throw CancellationError() }
        }
    }

    // MARK: - Explicit consent

    @Test
    func consentIsSingleUseAndBoundToChatAndUser() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("data", name: "log.txt")
        let broker = TerminalTelegramArtifactConsentBroker()
        let artifact = TerminalTelegramArtifact(fileURL: url, filename: "log.txt")

        let offerID = try await broker.offerConsent(
            artifact: artifact, chatID: 7, userID: 100
        )
        #expect(offerID != nil)

        // Wrong user: refused, and the offer is spent.
        let wrongUser = try await broker.consume(
            offerID: offerID!, chatID: 7, userID: 999, artifactFingerprint: nil
        )
        #expect(wrongUser == nil)

        // Replay: nothing left to consume.
        let replay = try await broker.consume(
            offerID: offerID!, chatID: 7, userID: 100, artifactFingerprint: nil
        )
        #expect(replay == nil)
    }

    @Test
    func consentRefusesSameSizeArtifactWhoseBytesChangedAfterOffer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("AAAA", name: "mutable.diff")
        let artifact = TerminalTelegramArtifact(fileURL: url, filename: "mutable.diff")
        let broker = TerminalTelegramArtifactConsentBroker()
        let offerID = try #require(try await broker.offerConsent(
            artifact: artifact, chatID: 42, userID: 7
        ))
        try Data("BBBB".utf8).write(to: url, options: .atomic)
        let consumed = try await broker.consume(
            offerID: offerID, chatID: 42, userID: 7,
            artifactFingerprint: TerminalTelegramArtifactConsentBroker.fingerprint(of: artifact)
        )
        #expect(consumed == nil)
    }

    @Test
    func stopFencesSuspendedInboundDownloadBeforeFileGET() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-stop-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], telegram: AgentTelegramSettingsManifest(
                enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
                linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "default")]
            )),
            to: support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        let transport = LifecycleDownloadGateTransport()
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let state = try await service.start()
            let attachment = TerminalTelegramInboundAttachment(
                fileID: "file", fileUniqueID: nil, kind: .document,
                mimeType: "text/plain", fileSize: 4, fileName: "note.txt", messageID: 1
            )
            let receive = Task {
                try await service.receiveInboundAttachment(
                    attachment, chatID: 42, fence: Self.wireFence(epoch: try #require(state.wireLifecycleEpoch))
                )
            }
            await transport.waitUntilStarted()
            let stopped = Mutex(false)
            let stop = Task {
                _ = await service.stop()
                stopped.withLock { $0 = true }
            }
            await Task.yield()
            #expect(!stopped.withLock { $0 })
            await transport.releaseGetFile()
            await #expect(throws: CancellationError.self) { try await receive.value }
            _ = await stop.value
            #expect(stopped.withLock { $0 })
            #expect(await transport.methods == ["getFile"])
            #expect(await service.inboundAttachments.storedFilenames(chatID: 42).isEmpty)
        }
    }

    @Test
    func stopWaitsForSuspendedArtifactUploadAndRetiredGenerationCannotResume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("artifact", name: "artifact.txt")
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-stop-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], telegram: AgentTelegramSettingsManifest(
                enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
                linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "default")]
            )),
            to: support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        let transport = LifecycleUploadGateTransport()
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let state = try await service.start()
            let artifact = TerminalTelegramArtifact(fileURL: url, filename: "artifact.txt")
            let offerID = try #require(try await service.offerArtifactConsent(
                artifact: artifact, chatID: 42, userID: 7, routeLease: Self.routeLease
            ))
            let upload = Task {
                try await service.sendArtifactWithConsent(
                    offerID: offerID, chatID: 42, userID: 7,
                    routeLease: Self.routeLease, policy: fixture.policy,
                    topicID: nil, fence: Self.wireFence(epoch: try #require(state.wireLifecycleEpoch))
                )
            }
            await transport.waitUntilStarted()
            let stopped = Mutex(false)
            let stop = Task {
                _ = await service.stop()
                stopped.withLock { $0 = true }
            }
            await Task.yield()
            #expect(!stopped.withLock { $0 })
            await transport.release()
            await #expect(throws: CancellationError.self) { try await upload.value }
            _ = await stop.value
            #expect(stopped.withLock { $0 })
            #expect(await transport.attempts == 1)
        }
    }
}

private actor LifecycleDownloadGateTransport: TelegramHTTPTransport {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var methods: [String] = []

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func releaseGetFile() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let apiMethod = url.lastPathComponent
        switch apiMethod {
        case "deleteWebhook", "setMyCommands":
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "getMe":
            return (200, Data(#"{"ok":true,"result":{"id":9101,"is_bot":true,"first_name":"bot"}}"#.utf8))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        default:
            break
        }
        methods.append(apiMethod)
        if apiMethod == "getFile" {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
            return (200, Data(#"{"ok":true,"result":{"file_id":"file","file_size":4,"file_path":"documents/note.txt"}}"#.utf8))
        }
        return (200, Data("data".utf8))
    }
}

private actor LifecycleUploadGateTransport: TelegramHTTPTransport {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var attempts = 0

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        switch url.lastPathComponent {
        case "deleteWebhook", "setMyCommands":
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "getMe":
            return (200, Data(#"{"ok":true,"result":{"id":9102,"is_bot":true,"first_name":"bot"}}"#.utf8))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        default:
            break
        }
        attempts += 1
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return (200, Data(#"{"ok":true,"result":{"message_id":9,"chat":{"id":42,"type":"private"}}}"#.utf8))
    }
}

private extension TerminalTelegramArtifactConsentBroker {
    static var testRouteLease: TerminalTelegramRouteLease {
        .init(
            key: .init(chatID: 42, userID: 7, roomID: "artifact-test-room"),
            generation: 1
        )
    }

    func offerConsent(
        artifact: TerminalTelegramArtifact,
        chatID: Int64,
        userID: Int64,
        cleanupAfterUse: Bool = false
    ) throws -> String? {
        try offerConsent(
            artifact: artifact,
            chatID: chatID,
            userID: userID,
            routeLease: Self.testRouteLease,
            cleanupAfterUse: cleanupAfterUse
        )
    }

    func consume(
        offerID: String,
        chatID: Int64,
        userID: Int64,
        artifactFingerprint: ArtifactFingerprint?
    ) throws -> Offer? {
        try consume(
            offerID: offerID,
            chatID: chatID,
            userID: userID,
            routeLease: Self.testRouteLease,
            artifactFingerprint: artifactFingerprint
        )
    }
}
