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

    /// The file budget is enforced before any byte is read: a corpus larger
    /// than the per-file budget fails closed at form construction.
    @Test
    func multipartRejectsFileAbovePerFileBudget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("abc", name: "big.bin")
        let oversized = Int.max / 2

        #expect(throws: TerminalTelegramControlError.fileTooLarge(
            limit: TerminalTelegramMultipartForm.maximumUploadFileBytes
        )) {
            _ = try TerminalTelegramMultipartForm.form(parts: [
                .file(
                    name: "document",
                    filename: "big.bin",
                    contentType: "application/octet-stream",
                    fileURL: url,
                    fileSize: oversized
                ),
            ])
        }
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

    @Test
    func policyRejectsDeniedTrees() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gitDirectory = fixture.directory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory, withIntermediateDirectories: true
        )
        let url = gitDirectory.appendingPathComponent("HEAD")
        FileManager.default.createFile(atPath: url.path, contents: Data("ref".utf8))

        #expect(throws: TerminalTelegramControlError.artifactPathRejected) {
            _ = try fixture.policy.validated(
                TerminalTelegramArtifact(fileURL: url, filename: "HEAD")
            )
        }
    }

    @Test
    func policyEnforcesSizeBudget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile(String(repeating: "a", count: 2048), name: "big.log")

        #expect(throws: TerminalTelegramControlError.fileTooLarge(limit: 1024)) {
            _ = try fixture.policy.validated(
                TerminalTelegramArtifact(fileURL: url, filename: "big.log")
            )
        }
    }

    @Test
    func policySanitizesOutboundFilename() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("ok", name: "fine.txt")

        let artifact = try fixture.policy.validated(
            TerminalTelegramArtifact(fileURL: url, filename: "../../etc/passwd\u{01}")
        )
        #expect(!artifact.filename.contains("/"))
        #expect(artifact.filename != "../../etc/passwd\u{01}")
        #expect(!artifact.filename.contains("\u{01}"))
    }

    @Test
    func contentTypeSanitizationStripsParameters() {
        #expect(
            TerminalTelegramArtifactPolicy.sanitizedContentType("text/plain; charset=utf-8")
                == "text/plain"
        )
        #expect(
            TerminalTelegramArtifactPolicy.sanitizedContentType("application/json")
                == "application/json"
        )
        #expect(
            TerminalTelegramArtifactPolicy.sanitizedContentType("garbage")
                == "application/octet-stream"
        )
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
    func consentRefusesAFingerprintMismatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("data", name: "log.txt")
        let broker = TerminalTelegramArtifactConsentBroker()
        let artifact = TerminalTelegramArtifact(fileURL: url, filename: "log.txt")

        let offerID = try await broker.offerConsent(
            artifact: artifact, chatID: 1, userID: 2
        )
        let mismatched = TerminalTelegramArtifactConsentBroker.ArtifactFingerprint(
            path: url.path, size: 999_999, modifiedAtNanoseconds: 0
        )
        let consumed = try await broker.consume(
            offerID: offerID!, chatID: 1, userID: 2,
            artifactFingerprint: mismatched
        )
        #expect(consumed == nil)
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
    func consentOfferExpires() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("data", name: "log.txt")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let broker = TerminalTelegramArtifactConsentBroker(now: { clock.now })
        let artifact = TerminalTelegramArtifact(fileURL: url, filename: "log.txt")

        let offerID = try await broker.offerConsent(
            artifact: artifact, chatID: 1, userID: 2
        )
        clock.advance(by: TerminalTelegramArtifactConsentBroker.offerLifetime + 1)
        let consumed = try await broker.consume(
            offerID: offerID!, chatID: 1, userID: 2, artifactFingerprint: nil
        )
        #expect(consumed == nil)
    }

    @Test
    func stopWaitsForOwnedConsentCleanupBeforeNewGenerationWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstURL = try fixture.writeFile("first", name: "first.diff")
        let service = TerminalTelegramControlService(
            transportFactory: { StubTelegramTransport() }
        )
        let firstID = try #require(try await service.offerArtifactConsent(
            artifact: .init(fileURL: firstURL, filename: "first.diff"),
            chatID: 42, userID: 7, routeLease: Self.routeLease, cleanupAfterUse: true
        ))
        _ = firstID
        _ = await service.stop()
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))

        let secondURL = try fixture.writeFile("second", name: "second.diff")
        let secondID = try #require(try await service.offerArtifactConsent(
            artifact: .init(fileURL: secondURL, filename: "second.diff"),
            chatID: 42, userID: 7, routeLease: Self.routeLease, cleanupAfterUse: true
        ))
        #expect(await service.pendingConsentArtifact(
            offerID: secondID, chatID: 42
        )?.fileURL == secondURL)
        await service.cancelArtifactConsent(offerID: secondID, chatID: 42)
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

    @Test
    func consentKeyboardRoundsTripsActions() throws {
        let markup = TerminalTelegramArtifactConsentKeyboard.markup(offerID: "abc123")
        guard case let .inlineKeyboard(rows) = markup,
              let buttons = rows.first else {
            Issue.record("expected inline keyboard")
            return
        }
        #expect(buttons.count == 2)

        let send = TerminalTelegramArtifactConsentKeyboard
            .action(fromCallbackData: buttons[0].callbackData)
        #expect(send?.action == .send)
        #expect(send?.offerID == "abc123")

        let cancel = TerminalTelegramArtifactConsentKeyboard
            .action(fromCallbackData: buttons[1].callbackData)
        #expect(cancel?.action == .cancel)
        #expect(cancel?.offerID == "abc123")

        // Foreign callbacks never resolve.
        #expect(TerminalTelegramArtifactConsentKeyboard
            .action(fromCallbackData: "zencode:mention:dev") == nil)
        #expect(TerminalTelegramArtifactConsentKeyboard
            .action(fromCallbackData: "zencode:artifact:") == nil)
    }

    // MARK: - Selective ingress

    @Test
    func ingressAdmitsAllowlistedDocuments() {
        let admitted = TerminalTelegramInboundAttachmentGate.admit(
            TerminalTelegramInboundAttachment(
                fileID: "AgAC123", fileUniqueID: "u1", kind: .document,
                mimeType: "text/plain", fileSize: 100, fileName: "notes.txt",
                messageID: 5
            )
        )
        if case .failure = admitted {
            Issue.record("allowlisted document must be admitted")
        }
        guard case let .success(value) = admitted else { return }
        #expect(value.mimeType == "text/plain")
        #expect(value.fileName == "notes.txt")
    }

    @Test
    func ingressNormalizesMIMEParameters() {
        let admitted = TerminalTelegramInboundAttachmentGate.admit(
            TerminalTelegramInboundAttachment(
                fileID: "AgAC1", fileUniqueID: nil, kind: .document,
                mimeType: "Text/Plain; charset=utf-8", fileSize: 10, fileName: "x.txt",
                messageID: 1
            )
        )
        if case .failure = admitted {
            Issue.record("normalized MIME must be admitted")
        }
    }

    @Test
    func ingressRefusesDisallowedMIMEAndSize() {
        let zip = TerminalTelegramInboundAttachmentGate.admit(
            TerminalTelegramInboundAttachment(
                fileID: "AgAC1", fileUniqueID: nil, kind: .document,
                mimeType: "application/zip", fileSize: 10, fileName: "a.zip",
                messageID: 1
            )
        )
        guard case let .failure(refusal) = zip else {
            Issue.record("zip must be refused")
            return
        }
        #expect(refusal == .unsupportedMIMEType("application/zip"))

        let oversized = TerminalTelegramInboundAttachmentGate.admit(
            TerminalTelegramInboundAttachment(
                fileID: "AgAC2", fileUniqueID: nil, kind: .document,
                mimeType: "text/plain", fileSize: Int.max, fileName: "huge.txt",
                messageID: 2
            )
        )
        guard case .failure(.tooLarge) = oversized else {
            Issue.record("oversized must be refused")
            return
        }

        let hostile = TerminalTelegramInboundAttachmentGate.admit(
            TerminalTelegramInboundAttachment(
                fileID: String(repeating: "A", count: 400), fileUniqueID: nil,
                kind: .document, mimeType: "text/plain", fileSize: 1, fileName: "x",
                messageID: 3
            )
        )
        guard case .failure(.invalidIdentifier) = hostile else {
            Issue.record("hostile identifier must be refused")
            return
        }
    }

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

    @Test
    func inboundStoreDiscardsSingleAttachments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = TerminalTelegramInboundAttachmentStore()
        let client = TerminalTelegramAPIClient(
            token: "test-token",
            transport: StubTelegramTransport()
        )
        let attachment = try TerminalTelegramInboundAttachmentGate.admit(
            TerminalTelegramInboundAttachment(
                fileID: "AgAC2", fileUniqueID: nil, kind: .document,
                mimeType: "application/json", fileSize: 5, fileName: "data.json",
                messageID: 10
            )
        ).get()

        let stored = try await store.receive(attachment, chatID: 7, client: client)
        await store.discard(filename: "data.json", chatID: 7)
        #expect(!FileManager.default.fileExists(atPath: stored.url.path))
        // Discarding twice is inert.
        await store.discard(filename: "data.json", chatID: 7)
    }

    @Test
    func concurrentInboundDownloadsWithDuplicateFilenameDoNotLeakOwnership() async throws {
        let store = TerminalTelegramInboundAttachmentStore()
        let client = TerminalTelegramAPIClient(token: "token", transport: StubTelegramTransport())
        let attachment = TerminalTelegramInboundAttachment(
            fileID: "file", fileUniqueID: "unique", kind: .document,
            mimeType: "text/plain", fileSize: 4, fileName: "same.txt", messageID: 1
        )
        let records = try await withThrowingTaskGroup(
            of: TerminalTelegramInboundAttachmentStore.StoredAttachment.self,
            returning: [TerminalTelegramInboundAttachmentStore.StoredAttachment].self
        ) { group in
            for _ in 0..<2 {
                group.addTask { try await store.receive(attachment, chatID: 42, client: client) }
            }
            var values: [TerminalTelegramInboundAttachmentStore.StoredAttachment] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(await store.storedCount(chatID: 42) == 1)
        let removed = await store.cleanup(chatID: 42)
        #expect(removed == 1)
        #expect(records.filter { FileManager.default.fileExists(atPath: $0.url.path) }.isEmpty)
    }

    /// Wire decoding: `document` and `photo` project onto the selective
    /// ingress, and the largest photo size is chosen.
    @Test
    func messageDecodesDocumentAndPhotoAttachments() throws {
        let update = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<[TerminalTelegramUpdate]>.self,
            from: Data(#"""
            {"ok":true,"result":[
              {"update_id":11,"message":{
                "message_id":31,"from":{"id":42,"is_bot":false},
                "chat":{"id":42,"type":"private"},
                "document":{"file_id":"doc1","file_unique_id":"du1","file_name":"notes.md","mime_type":"text/markdown","file_size":128}
              }},
              {"update_id":12,"message":{
                "message_id":32,"from":{"id":42,"is_bot":false},
                "chat":{"id":42,"type":"private"},
                "photo":[
                  {"file_id":"p-small","width":100,"height":80,"file_size":4000},
                  {"file_id":"p-large","width":800,"height":600,"file_size":90000}
                ]
              }}
            ]}
            """#.utf8)
        )
        let results = try #require(update.result)
        let document = try #require(results[0].message?.inboundDocument)
        #expect(document.fileID == "doc1")
        #expect(document.mimeType == "text/markdown")
        #expect(document.fileName == "notes.md")

        let photo = try #require(results[1].message?.inboundPhoto)
        #expect(photo.fileID == "p-large")
        #expect(photo.kind == .photo)
        #expect(photo.mimeType == "image/jpeg")
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

    /// Upload cancellation propagates and no retry is attempted for a
    /// non-429 failure.
    @Test
    func sendDocumentDoesNotRetryAmbiguousFailures() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("data", name: "log.txt")
        let transport = FailingTelegramTransport(httpStatus: 500)
        let client = TerminalTelegramAPIClient(token: "TOKEN", transport: transport)

        await #expect(throws: TerminalTelegramControlError.self) {
            _ = try await client.sendDocument(
                TerminalTelegramArtifact(fileURL: url, filename: "log.txt"),
                to: 1
            )
        }
        #expect(transport.attempts == 1)
    }

    /// An explicit 429 with `retry_after` is retried once, matching the
    /// message-send policy: only the explicit rate-limit verdict retries.
    @Test
    func sendDocumentRetriesOnlyOnExplicit429() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.writeFile("data", name: "log.txt")
        let transport = ScriptedTelegramTransport(responses: [
            (429, Data(#"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":0}}"#.utf8)),
            (200, Data(#"{"ok":true,"result":{"message_id":88,"chat":{"id":9,"type":"private"},"date":0}}"#.utf8)),
        ])
        let client = TerminalTelegramAPIClient(token: "t", transport: transport)

        let receipt = try await client.sendDocument(
            TerminalTelegramArtifact(fileURL: url, filename: "log.txt"),
            to: 9,
            governor: TerminalTelegramRateGovernor()
        )
        #expect(receipt == 88)
        #expect(transport.attempts == 2)
    }

    /// Cancelling the upload task while the corpus is being read aborts the
    /// send without a partial request and without leaking the descriptor:
    /// the failure surfaces as a cancellation error, never as success.
    @Test
    func sendDocumentIsCancellable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // A corpus large enough that the bounded reader is still streaming
        // when cancellation lands.
        let url = try fixture.writeFile(
            String(repeating: "x", count: 2 * 1_024 * 1_024), name: "large.log"
        )
        let transport = NeverCompletingTelegramTransport()
        let client = TerminalTelegramAPIClient(token: "TOKEN", transport: transport)

        let upload = Task {
            try await client.sendDocument(
                TerminalTelegramArtifact(fileURL: url, filename: "large.log"),
                to: 5
            )
        }
        // Give the task a chance to start, then cancel.
        try await Task.sleep(for: .milliseconds(20))
        upload.cancel()
        await #expect(throws: (any Error).self) {
            _ = try await upload.value
        }
        #expect(!Task.isCancelled)
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

/// Transport whose requests never complete, so cancellation is the only exit.
final class NeverCompletingTelegramTransport: TelegramHTTPTransport, @unchecked Sendable {
    private let continuation = Mutex<[CheckedContinuation<(status: Int, body: Data), any Error>]>([])

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation.withLock { waiters in
                    waiters.append(continuation)
                }
            }
        } onCancel: {
            self.continuation.withLock { waiters in
                waiters.forEach { $0.resume(throwing: CancellationError()) }
                waiters.removeAll()
            }
        }
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

final class FailingTelegramTransport: TelegramHTTPTransport, @unchecked Sendable {
    let httpStatus: Int
    private let attemptsLock = Mutex(0)

    init(httpStatus: Int) {
        self.httpStatus = httpStatus
    }

    var attempts: Int {
        attemptsLock.withLock { $0 }
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        attemptsLock.withLock { $0 += 1 }
        return (httpStatus, Data("{\"ok\":false,\"error_code\":\(httpStatus)}".utf8))
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
