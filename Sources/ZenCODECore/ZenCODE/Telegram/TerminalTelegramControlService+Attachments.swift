//
//  TerminalTelegramControlService+Attachments.swift
//  ZenCODE
//
//  Outbound artifact consent, inbound attachment store, presence leases and
//  voice download of ``TerminalTelegramControlService``. Extracted verbatim
//  from TerminalTelegramControlService.swift; the dead private helper
//  `offerArtifact(of:chatID:)` (no call sites) was dropped during the move.
//

import Foundation
import ToolCore

extension TerminalTelegramControlService {
    // MARK: - Secure artifacts

    /// Records an explicit, single-use consent offer for uploading `artifact`
    /// to `chatID`, and returns the offer id to embed in the confirmation
    /// keyboard. Returns `nil` when the broker is saturated for that chat.
    public func offerArtifactConsent(
        artifact: TerminalTelegramArtifact,
        chatID: Int64,
        userID: Int64,
        routeLease: TerminalTelegramRouteLease,
        cleanupAfterUse: Bool = false
    ) async throws -> String? {
        try await artifactConsent.offerConsent(
            artifact: artifact, chatID: chatID, userID: userID, routeLease: routeLease,
            cleanupAfterUse: cleanupAfterUse
        )
    }

    /// Consumes a single-use consent offer. Re-validates the artifact against
    /// `policy` and the on-disk fingerprint before uploading; any mismatch,
    /// expiry or replay refuses the upload (fail-closed) and the offer is
    /// spent either way.
    @discardableResult
    public func sendArtifactWithConsent(
        offerID: String,
        chatID: Int64,
        userID: Int64,
        routeLease: TerminalTelegramRouteLease,
        policy: TerminalTelegramArtifactPolicy,
        topicID: Int?,
        caption: String? = nil,
        fence: TerminalTelegramWireFence
    ) async throws -> Int? {
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let pendingArtifact = await artifactConsent.pendingOffer(
            offerID: offerID, chatID: chatID
        )?.artifact
        guard let offer = try await artifactConsent.consume(
            offerID: offerID,
            chatID: chatID,
            userID: userID,
            routeLease: routeLease,
            artifactFingerprint: pendingArtifact.flatMap {
                TerminalTelegramArtifactConsentBroker.fingerprint(of: $0)
            }
        ) else {
            return nil
        }
        defer {
            if offer.cleanupAfterUse {
                try? FileManager.default.removeItem(at: offer.artifact.fileURL)
            }
        }
        let validated = try policy.validated(offer.artifact)
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let receipt = try await wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: chatID, topicID: topicID
        )
            .sendDocument(
                validated, to: chatID, messageThreadID: topicID, caption: caption,
                expectedSHA256: offer.fingerprint.sha256,
                governor: rateGovernor
            )
        try ensureCurrentWireGeneration(wireGeneration)
        return receipt
    }

    /// Reads back the artifact of a still-pending offer, when present.
    public func pendingConsentArtifact(
        offerID: String, chatID: Int64
    ) async -> TerminalTelegramArtifact? {
        await artifactConsent.pendingOffer(
            offerID: offerID, chatID: chatID
        )?.artifact
    }

    /// Cancels a pending consent offer without uploading. Idempotent.
    public func cancelArtifactConsent(offerID: String, chatID: Int64) async {
        await artifactConsent.cancel(offerID: offerID, chatID: chatID)
    }

    /// Receives an admitted inbound attachment into the bounded store.
    public func receiveInboundAttachment(
        _ attachment: TerminalTelegramInboundAttachment,
        chatID: Int64,
        fence: TerminalTelegramWireFence
    ) async throws -> (url: URL, filename: String, mimeType: String) {
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let client = wireClient(token: token, generation: wireGeneration, fence: fence, chatID: chatID, topicID: topicID)
        let stored = try await inboundAttachments.receive(
            attachment, chatID: chatID, client: client,
            validateBeforeDownload: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.ensureCurrentWireGeneration(wireGeneration)
            }
        )
        try ensureCurrentWireGeneration(wireGeneration)
        return (stored.url, stored.filename, stored.mimeType)
    }

    /// Lists received-but-unconsumed attachments for a chat.
    public func inboundAttachmentFilenames(chatID: Int64) async -> [String] {
        await inboundAttachments.storedFilenames(chatID: chatID)
    }

    /// Deletes one inbound temporary. Idempotent.
    public func discardInboundAttachment(filename: String, chatID: Int64) async {
        await inboundAttachments.discard(filename: filename, chatID: chatID)
    }

    /// Deterministic cleanup of every inbound temporary for a chat.
    @discardableResult
    public func cleanupInboundAttachments(chatID: Int64? = nil) async -> Int {
        await inboundAttachments.cleanup(chatID: chatID)
    }

    // MARK: - Presence

    /// Takes a lifecycle-safe presence lease for `scope` and starts renewing
    /// the typing indicator. The lease is fenced by generation: releasing it,
    /// replacing it, or `stop()` kills the renewal loop at its next wake-up.
    public func acquirePresenceLease(
        scope: TerminalTelegramPresenceScope,
        fence: TerminalTelegramWireFence
    ) async -> TerminalTelegramPresenceLeaseManager.Lease? {
        guard state.isActive,
              scope.chatID == fence.lease.key.chatID,
              scope.topicID == fence.lease.effectiveMessageThreadID else {
            return nil
        }
        return await presenceLeaseManager.acquire(scope: scope, fence: fence)
    }

    func sendPresenceAction(_ scope: TerminalTelegramPresenceScope) async {
        guard let fence = await presenceLeaseManager.currentFence(for: scope),
              let generation = try? await beginWireEffect(
                fence: fence, chatID: scope.chatID, topicID: scope.topicID
              ) else { return }
        defer { endWireEffect(fence: fence) }
        guard let settings = try? telegramSettings(),
              let token = try? telegramToken(from: settings) else { return }
        try? await wireClient(
            token: token, generation: generation, fence: fence,
            chatID: scope.chatID, topicID: scope.topicID
        ).sendChatAction(action: "typing", to: scope.chatID)
    }

    /// Releases a presence lease previously taken. Inert when the lease was
    /// already released or replaced.
    public func releasePresenceLease(
        _ lease: TerminalTelegramPresenceLeaseManager.Lease
    ) async {
        await presenceLeaseManager.release(lease)
    }

    public func downloadVoiceAudio(
        _ voice: TerminalTelegramVoiceAttachment,
        chatID: Int64? = nil,
        fence: TerminalTelegramWireFence
    ) async throws -> AgentVoiceAudioInput {
        let resolvedChatID = chatID ?? fence.lease.key.chatID
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(
            fence: fence, chatID: resolvedChatID, topicID: topicID
        )
        defer { endWireEffect(fence: fence) }
        if let fileSize = voice.fileSize,
           fileSize > TerminalTelegramAPIClient.maximumAudioFileBytes {
            throw TerminalTelegramControlError.fileTooLarge(
                limit: TerminalTelegramAPIClient.maximumAudioFileBytes
            )
        }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let downloadedFile = try await wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: resolvedChatID, topicID: topicID
        )
            .downloadFile(
                fileID: voice.fileID,
                validateBeforeDownload: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.ensureCurrentWireGeneration(wireGeneration)
                }
            )
        try ensureCurrentWireGeneration(wireGeneration)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-telegram-voice-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: downloadedFile.filename))
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: downloadedFile.data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try ensureCurrentWireGeneration(wireGeneration)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return AgentVoiceAudioInput(
            fileURL: temporaryURL,
            filename: downloadedFile.filename,
            contentType: voice.mimeType ?? Self.contentType(for: downloadedFile.filename),
            removeAfterUse: true
        )
    }

    private nonisolated static func contentType(for filename: String) -> String? {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "oga", "ogg":
            return "audio/ogg"
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        default:
            return nil
        }
    }

    private nonisolated static func fileExtension(for filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.nilIfBlank ?? "oga"
    }
}
