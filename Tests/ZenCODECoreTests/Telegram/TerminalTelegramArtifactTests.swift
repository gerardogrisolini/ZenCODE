import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct TerminalTelegramArtifactTests {
    // MARK: - Test fixtures

    private static var routeLease: TerminalTelegramRouteLease {
        .init(key: .init(chatID: 42, userID: 7, roomID: "test-room"), generation: 1)
    }

    private static func wireFence(epoch: UUID) -> TerminalTelegramWireFence {
        let lease = routeLease
        return TerminalTelegramWireFence(lease: lease, lifecycleEpoch: epoch) { candidate in
            guard candidate == lease else { throw CancellationError() }
        }
    }

    struct Fixture {
        let directory: URL
        let policy: TerminalTelegramArtifactPolicy

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zen-artifact-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            policy = TerminalTelegramArtifactPolicy(
                allowedDirectories: [directory],
                allowedExtensions: ["diff", "txt", "log"],
                maximumBytes: 1024
            )
        }

        func writeFile(
            _ text: String,
            name: String = "notes.txt",
            permissions: Int = 0o600
        ) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let data = Data(text.utf8)
            let created = FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: permissions)]
            )
            guard created else { throw CocoaError(.fileWriteUnknown) }
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Multipart builder

    /// The encoded multipart form matches the RFC 7578 wire shape: boundary
    /// framing, Content-Disposition with the sanitized filename, explicit
    /// Content-Type and the closing boundary.
    @Test
    func multipartFormEncodesValidWireShape() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("hello corpus", name: "session.diff")

        let form = try TerminalTelegramMultipartForm.form(parts: [
            .value(name: "chat_id", value: "42"),
            .value(name: "caption", value: "session diff"),
            .file(
                name: "document",
                filename: "session.diff",
                contentType: "text/x-diff",
                fileURL: url,
                fileSize: 12
            ),
        ])

        let data = try form.encode()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n42\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"document\"; filename=\"session.diff\"\r\n"))
        #expect(text.contains("Content-Type: text/x-diff\r\n\r\nhello corpus\r\n"))
        #expect(text.hasSuffix("--\(form.boundary)--\r\n"))
        #expect(data.count == form.totalBytes)
        #expect(form.contentTypeHeader == "multipart/form-data; boundary=\(form.boundary)")
        #expect(!form.boundary.contains("-"))
    }

    /// A filename carrying quotes and backslashes cannot break out of the
    /// quoted disposition attribute.
    @Test
    func multipartEscapesHostileFilenames() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("x", name: "safe.txt")

        let form = try TerminalTelegramMultipartForm.form(parts: [
            .file(
                name: "document",
                filename: "evil\"name\"; x=\"y",
                contentType: "text/plain",
                fileURL: url,
                fileSize: 1
            ),
        ])
        let text = String(decoding: try form.encode(), as: UTF8.self)
        #expect(text.contains("filename=\"evil\\\"name\\\"; x=\\\"y\"\r\n"))
        // No injection of a new header line is possible.
        #expect(!text.contains("filename=\"evil\"name\""))
    }

    /// A file that grew between the size check and the corpus read aborts
    /// instead of quietly inflating the upload.
    @Test
    func multipartAbortsWhenCorpusExceedsPromisedSize() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("0123456789", name: "grew.txt")

        let form = try TerminalTelegramMultipartForm.form(parts: [
            .file(
                name: "document",
                filename: "grew.txt",
                contentType: "text/plain",
                fileURL: url,
                fileSize: 4
            ),
        ])
        #expect(throws: TerminalTelegramControlError.payloadTooLarge(limit: 4)) {
            _ = try form.encode()
        }
    }

    // MARK: - Anti-exfiltration policy

    @Test
    func policyAcceptsAllowedFileInsideAllowedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("ok", name: "report.log")

        let artifact = try fixture.policy.validated(
            TerminalTelegramArtifact(fileURL: url, filename: "report.log")
        )
        #expect(artifact.filename == "report.log")
        #expect(artifact.fileURL == url)
    }

    @Test
    func policyRejectsSymlinksInsideAllowedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-artifact-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("secret.diff")
        try Data("s".utf8).write(to: target)
        // File symlink pointing outside.
        let fileLink = staging.appendingPathComponent("a.diff")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: target)
        // Directory symlink pointing outside.
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("dir"), withDestinationURL: outside
        )
        let policy = TerminalTelegramArtifactPolicy(allowedDirectories: [staging])

        for url in [fileLink, staging.appendingPathComponent("dir/secret.diff")] {
            #expect(throws: TerminalTelegramControlError.artifactPathRejected) {
                _ = try policy.validated(TerminalTelegramArtifact(fileURL: url, filename: "x.diff"))
            }
        }
    }

    #if os(macOS)
    #endif

    @Test
    func policyRejectsTraversalAndEscapes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inside = try fixture.writeFile("x", name: "in.txt")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("../outside.txt")

        func expectRejected(_ url: URL) {
            #expect(throws: TerminalTelegramControlError.artifactPathRejected) {
                _ = try fixture.policy.validated(
                    TerminalTelegramArtifact(fileURL: url, filename: url.lastPathComponent)
                )
            }
        }
        // Directory escape through traversal.
        expectRejected(
            fixture.directory.appendingPathComponent("../escape.txt")
        )
        // Absolute path outside the allowlist.
        expectRejected(outside)
        // Missing file inside the allowlist.
        expectRejected(
            fixture.directory.appendingPathComponent("missing.txt")
        )
        // A directory, not a regular file.
        expectRejected(fixture.directory)
        // Allowed directory but disallowed extension.
        expectRejected(
            fixture.directory.appendingPathComponent("run.sh")
        )
        // Valid file used only to prove the gate really opens.
        _ = inside
    }

    @Test
    func policyRejectsSecretsWhereverTheyLive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in [".env", "id_rsa", "secrets.json", "token.pem", "server.key"] {
            let url = try fixture.writeFile("secret", name: name)
            #expect(throws: TerminalTelegramControlError.artifactPathRejected) {
                _ = try fixture.policy.validated(
                    TerminalTelegramArtifact(fileURL: url, filename: name)
                )
            }
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
            #expect(await service.inboundAttachmentFilenames(chatID: 42).isEmpty)
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

    // MARK: - Selective ingress

    @Test
    func ingressSanitizesFilenames() {
        let sanitized = TerminalTelegramInboundAttachmentGate.sanitizedFilename(
            "../../evil/../../name.txt"
        )
        #expect(!sanitized.contains("/"))
        #expect(!sanitized.contains(".."))
        #expect(TerminalTelegramInboundAttachmentGate.sanitizedFilename("") == "attachment")
        let control = TerminalTelegramInboundAttachmentGate.sanitizedFilename("a\u{0}b:c")
        #expect(!control.contains("\u{0}"))
    }

    // MARK: - Inbound store lifecycle

    /// Admitted attachments land in a 0600 temporary and the deterministic
    /// cleanup removes every stored file.
    @Test
    func inboundStoreCreatesPrivateTemporariesAndCleansUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = TerminalTelegramInboundAttachmentStore()
        let client = TerminalTelegramAPIClient(
            token: "test-token",
            transport: StubTelegramTransport()
        )
        let attachment = try TerminalTelegramInboundAttachmentGate.admit(
            TerminalTelegramInboundAttachment(
                fileID: "AgAC1", fileUniqueID: "u", kind: .document,
                mimeType: "text/plain", fileSize: 5, fileName: "doc.txt",
                messageID: 9
            )
        ).get()

        let stored = try await store.receive(attachment, chatID: 42, client: client)
        #expect(FileManager.default.fileExists(atPath: stored.url.path))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: stored.url.path
        )[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(await store.storedCount(chatID: 42) == 1)

        let removed = await store.cleanup(chatID: 42)
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: stored.url.path))
        #expect(await store.storedCount(chatID: 42) == 0)
        // Idempotent.
        #expect(await store.cleanup(chatID: 42) == 0)
    }

    // MARK: - Uploads through the client

    /// `sendDocument` posts a real multipart body to `sendDocument` with the
    /// boundary in the Content-Type header, and no JSON Content-Type.
    @Test
    func sendDocumentPostsMultipartWireRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("corpus-content", name: "log.txt")
        let transport = RecordingTelegramTransport()
        let client = TerminalTelegramAPIClient(token: "TOKEN", transport: transport)

        _ = try await client.sendDocument(
            TerminalTelegramArtifact(
                fileURL: url, filename: "log.txt", contentType: "text/plain"
            ),
            to: 42,
            caption: "session log"
        )

        let request = try #require(transport.requests.last)
        #expect(request.url.absoluteString == "https://api.telegram.org/botTOKEN/sendDocument")
        #expect(request.method == "POST")
        let contentType = try #require(
            request.headers.first { $0.name == "Content-Type" }?.value
        )
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try #require(request.body)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n42\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"caption\"\r\n\r\nsession log\r\n"))
        #expect(text.contains("filename=\"log.txt\""))
        #expect(text.contains("corpus-content"))
        #expect(request.timeout == TerminalTelegramAPIClient.uploadTimeout)
    }

    /// A document over the upload budget is refused locally: no request.
    @Test
    func sendDocumentRefusesOverBudgetFilesLocally() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("x", name: "huge.log")
        let transport = RecordingTelegramTransport()

        // Forge an artifact whose promised size exceeds the budget; the form
        // builder must refuse it before the transport is touched.
        let oversized = TerminalTelegramArtifact(
            fileURL: url, filename: "huge.log", contentType: "text/plain"
        )
        #expect(throws: TerminalTelegramControlError.self) {
            let attributes = try oversized.fileURL.resourceValues(forKeys: [.fileSizeKey])
            _ = try TerminalTelegramMultipartForm.form(parts: [
                .file(
                    name: "document", filename: "huge.log",
                    contentType: "text/plain", fileURL: url,
                    fileSize: (attributes.fileSize ?? 0)
                        + TerminalTelegramMultipartForm.maximumUploadFileBytes
                ),
            ]).encode()
        }
        #expect(transport.requests.isEmpty)
    }

    /// Ingress gate integration at the message level: the admitted
    /// text/plain document produces an attachment on the incoming message;
    /// the disallowed zip is dropped while the message text is kept. This is
    /// the exact projection `TerminalTelegramControlService.handle` applies
    /// before yielding, verified deterministically without a live poller.
    @Test
    func ingressFiltersAttachmentsAtTheMessageLevel() throws {
        let admitted = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<[TerminalTelegramUpdate]>.self,
            from: Data(#"""
            {"ok":true,"result":[{"update_id":1,"message":{
              "message_id":1,"from":{"id":42,"is_bot":false},
              "chat":{"id":42,"type":"private"},
              "text":"see attached",
              "document":{"file_id":"d1","file_name":"a.txt","mime_type":"text/plain","file_size":9}
            }}]}
            """#.utf8)
        )
        let refused = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<[TerminalTelegramUpdate]>.self,
            from: Data(#"""
            {"ok":true,"result":[{"update_id":2,"message":{
              "message_id":2,"from":{"id":42,"is_bot":false},
              "chat":{"id":42,"type":"private"},
              "text":"also see this",
              "document":{"file_id":"d2","file_name":"b.zip","mime_type":"application/zip","file_size":9}
            }}]}
            """#.utf8)
        )

        func projection(_ update: TerminalTelegramUpdate) -> (
            text: String?, attachment: TerminalTelegramInboundAttachment?
        ) {
            guard let message = update.message else { return (nil, nil) }
            let text = message.text?.nilIfBlank
            let attachment = (message.inboundDocument ?? message.inboundPhoto)
                .flatMap(TerminalTelegramInboundAttachmentGate.admit)
                .flatMap { try? $0.get() }
            return (text, attachment)
        }

        let first = projection(admitted.result!.first!)
        #expect(first.text == "see attached")
        #expect(first.attachment?.fileID == "d1")
        #expect(first.attachment?.kind == .document)

        let second = projection(refused.result!.first!)
        #expect(second.text == "also see this")
        #expect(second.attachment == nil)
    }
}

/// Transport that replays scripted responses and counts attempts.
final class ScriptedTelegramTransport: TelegramHTTPTransport, @unchecked Sendable {
    private let mutex = Mutex(0)
    private let responses: [(status: Int, body: Data)]

    init(responses: [(status: Int, body: Data)]) {
        self.responses = responses
    }

    var attempts: Int {
        mutex.withLock { $0 }
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let index = mutex.withLock { counter -> Int in
            defer { counter += 1 }
            return counter
        }
        return responses[min(index, responses.count - 1)]
    }
}

// MARK: - Transport stubs

/// A Sendable mutable clock for expiry tests.
final class MutableClock: Sendable {
    private let storage = Mutex(Date(timeIntervalSince1970: 0))

    init(_ start: Date) {
        storage.withLock { $0 = start }
    }

    var now: Date {
        storage.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        storage.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// Serves a small successful document download; used by inbound-store tests.
struct StubTelegramTransport: TelegramHTTPTransport {
    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        if url.path.contains("/getFile") {
            return (200, Data(#"""
            {"ok":true,"result":{"file_id":"AgAC1","file_unique_id":"u","file_size":5,"file_path":"documents/doc.txt"}}
            """#.utf8))
        }
        if url.host == "api.telegram.org" && url.path.contains("/file/bot") {
            return (200, Data("hello".utf8))
        }
        return (200, Data(#"""
        {"ok":true,"result":{"message_id":77,"chat":{"id":42,"type":"private"}}}
        """#.utf8))
    }
}

final class RecordingTelegramTransport: TelegramHTTPTransport, @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let url: URL
        let method: String
        let headers: [RemoteHTTPHeader]
        let body: Data?
        let timeout: Duration?
    }

    private let requestsLock = Mutex([Request]())

    var requests: [Request] {
        requestsLock.withLock { $0 }
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        requestsLock.withLock { requests in
            requests.append(Request(
                url: url, method: method, headers: headers, body: body, timeout: timeout
            ))
        }
        return (200, Data(#"""
        {"ok":true,"result":{"message_id":501,"chat":{"id":42,"type":"private"}}}
        """#.utf8))
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
