//
//  TelegramChannelArtifactsTests.swift
//  ZenCODE
//
//  What a ``TelegramChannel`` does with media: voice notes (the gates, a
//  download that fails, the outcomes of a transcription, the cancellation
//  that closes admission for good), `/diff` and the artifact consent buttons,
//  and inbound attachments. The channel is linked by hand to chat 42 or
//  attached to a Bot API double; nothing reaches a file or a transcription
//  service; every test runs in a UUID support directory.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Telegram channel artifacts", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelArtifactsTests {
    private typealias Support = TelegramChannelTestSupport

    private static let voiceNote = TerminalTelegramVoiceAttachment(
        fileID: "voice-1", fileUniqueID: nil, duration: 2, mimeType: "audio/ogg", fileSize: 4
    )

    private static let patchedSummary = TurnFileChangeSummary(entries: [
        .init(
            path: "Value.swift", additions: 1, deletions: 1, status: .modified,
            isBinary: false, existedBefore: true, beforeDataBase64: nil,
            patch: "--- a/Value.swift\n+++ b/Value.swift\n@@ -1 +1 @@\n-let value = 1\n+let value = 2"
        ),
        .init(
            path: "Added.swift", additions: 3, deletions: 0, status: .added,
            isBinary: false, existedBefore: false, beforeDataBase64: nil, patch: nil
        ),
    ])

    // MARK: - Voice

    /// A voice note goes through the work seam first; without a voice
    /// configuration it is refused with the transcription's text, and
    /// nothing is downloaded.
    @Test
    func voiceNotesPassTheGates() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-voice-\(UUID().uuidString)")
            let channel = pair.channel
            let effects = TelegramTestRecorder<TelegramChannel.TelegramWorkEffectForTesting>()
            channel.onTelegramWorkEffectForTesting = { effect in
                effects.append(effect)
                return true
            }
            await channel.handleVoiceMessage(Self.voiceNote, lease: pair.lease)
            #expect(effects.values == [.voiceTranscription])
            #expect(pair.texts.values.isEmpty)

            channel.onTelegramWorkEffectForTesting = nil
            #expect(!channel.isVoiceConfigured)
            await channel.handleVoiceMessage(Self.voiceNote, lease: pair.lease)
            #expect(pair.texts.values == [AgentVoiceTranscriptionError.notEnabledMessage])
            #expect(channel.voiceTranscriptions.activeCount == 0)
            #expect(await pair.transport.requestCount == 0)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A voice note that cannot be downloaded runs in a slot of the channel,
    /// frees it, and its failure reaches the primary channel and the chat.
    /// Telegram is a scripted transport: no file and no transcription
    /// service is reached.
    @Test
    func failedVoiceDownloadIsReportedToThePrimaryChannelAndTheChat() async throws {
        try await Support.withSupport(voice: AgentVoiceSettingsManifest(enabled: true)) {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, _, _ in prompts.append(prompt) }
            try await channel.attach()
            recorder.clear()
            let lease = try #require(channel.activeRouteLease)

            await channel.handleVoiceMessage(Self.voiceNote, lease: lease)
            try await Support.waitUntil { channel.voiceTranscriptions.activeCount == 0 }

            #expect(channel.voiceTranscriptions.activeCount == 0)
            #expect(prompts.values.isEmpty)
            let notice = try #require(recorder.notices.first)
            #expect(recorder.notices.count == 1)
            #expect(notice.channel == .failure)
            #expect(notice.text.hasPrefix("ZenCODE: ") && notice.text.hasSuffix("\n"))
            let failure = String(notice.text.dropFirst("ZenCODE: ".count).dropLast())
            #expect(!failure.isEmpty)
            #expect(await transport.sentTexts.last == "Voice transcription failed: \(failure)")
            await terminal.sessionHost.shutdown()
        }
    }

    /// A transcript runs as a direct prompt while the channel drives the
    /// slot; a full queue and a failure are told on the primary channel and
    /// in the chat with the terminal's texts; a transcript of a channel that
    /// no longer drives the slot is dropped.
    @Test
    func transcriptionOutcomesGoThroughTheChannel() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-voice-\(UUID().uuidString)")
            let channel = pair.channel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, lease, purpose in
                prompts.append("\(prompt)|\(lease == pair.lease)|\(purpose == .normal)")
            }
            pair.terminal.sessionHost.slots[pair.terminal.terminalSlotID]?.setActiveChannel(.telegram)

            await channel.voiceTranscriptionDidFinish(.success("summarize the diff"), lease: pair.lease)
            try await Support.waitUntil { !prompts.values.isEmpty }
            #expect(prompts.values == ["summarize the diff|true|true"])
            #expect(recorder.notices.isEmpty)
            #expect(pair.texts.values.isEmpty)
            // The channel's turn task ends after the turn it ran.
            try await Support.waitUntil { channel.activeTurnTask == nil }
            #expect(channel.activeTurnTask == nil)

            // A held queue with no room left.
            channel.promptQueue = ChatPromptQueue(capacity: 1)
            _ = channel.promptQueue.enqueue(ChatQueuedPrompt(text: "already waiting", origin: pair.lease))
            let hold = Task<Void, Never> {
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
            }
            channel.activeTurnTask = hold
            await channel.voiceTranscriptionDidFinish(.success("again"), lease: pair.lease)
            #expect(recorder.notices == [
                .init(text: "ZenCODE: prompt queue is full; voice prompt was not queued.\n", channel: .failure),
            ])
            #expect(pair.texts.values == ["ZenCODE: prompt queue is full; voice prompt was not queued."])
            hold.cancel()
            channel.activeTurnTask = nil
            channel.promptQueue = ChatPromptQueue()
            recorder.clear()

            await channel.voiceTranscriptionDidFinish(.failure("Telegram file is unavailable."), lease: pair.lease)
            #expect(recorder.notices == [
                .init(text: "ZenCODE: Telegram file is unavailable.\n", channel: .failure),
            ])
            #expect(pair.texts.values.last == "Voice transcription failed: Telegram file is unavailable.")

            // Not driving the slot: the transcript has no session to run on.
            pair.terminal.sessionHost.slots[pair.terminal.terminalSlotID]?.setActiveChannel(.primary)
            await channel.voiceTranscriptionDidFinish(.success("dropped"), lease: pair.lease)
            #expect(prompts.values.count == 1)
            #expect(pair.texts.values.count == 2)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// `cancelVoiceTranscriptions()` cancels a transcription in flight,
    /// waits for it, and closes admission for good: a later resume, as an
    /// attach does, does not reopen it.
    @Test
    func cancellingVoiceTranscriptionsClosesAdmissionForGood() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-voice-\(UUID().uuidString)")
            let registry = pair.channel.voiceTranscriptions
            let slot = try #require(registry.reserveSlot())
            let cancelled = TelegramTestRecorder<Bool>()
            let task = Task {
                defer { registry.release(slot) }
                try? await Task.sleep(for: .seconds(60))
                cancelled.append(Task.isCancelled)
            }
            registry.register(task, for: slot)

            await pair.channel.cancelVoiceTranscriptions()

            #expect(cancelled.values == [true])
            #expect(registry.activeCount == 0)
            #expect(registry.isShutDown)
            #expect(registry.reserveSlot() == nil)
            registry.resume()
            #expect(registry.reserveSlot() == nil)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Artifacts

    /// `/diff` without an excerpt to send is answered with the terminal's
    /// text and stages nothing: no summary, and a summary whose only patch
    /// exceeds the upload budget.
    @Test
    func diffWithoutAnExcerptIsAnswered() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-diff-\(UUID().uuidString)")
            let channel = pair.channel
            let staging = Self.temporaryStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            channel.artifactStagingDirectory = staging

            await channel.handleDiffRequest(lease: pair.lease)
            pair.terminal.lastFileChangeSummary = TurnFileChangeSummary(entries: [
                .init(
                    path: "Big.swift", additions: 1, deletions: 0, status: .modified,
                    isBinary: false, existedBefore: true, beforeDataBase64: nil,
                    patch: String(repeating: "+", count: TerminalTelegramMultipartForm.maximumBodyBytes + 1)
                ),
            ])
            #expect(channel.controller?.lastFileChangeSummary != nil)
            await channel.handleDiffRequest(lease: pair.lease)

            #expect(pair.texts.values == Array(
                repeating: "ZenCODE message: no diff is available for this session yet.", count: 2
            ))
            #expect(!FileManager.default.fileExists(atPath: staging.path))
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// `/diff` stages the bounded excerpt 0600 in the channel's staging
    /// directory, created 0700, and asks for consent with the two buttons;
    /// Cancel spends the offer, which removes the excerpt.
    @Test
    func diffStagesAPrivateExcerptAndCancelRemovesIt() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            let staging = Self.temporaryStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            channel.artifactStagingDirectory = staging
            terminal.lastFileChangeSummary = Self.patchedSummary

            await channel.handleDiffRequest(lease: lease)

            let files = try FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil
            )
            #expect(files.count == 1)
            let excerpt = try #require(files.first)
            #expect(excerpt.lastPathComponent.hasPrefix("session-\(terminal.sessionID.prefix(8))-"))
            #expect(excerpt.pathExtension == "diff")
            let added = Self.patchedSummary.entries[1].status.rawValue
            #expect(channel.sessionDiffText() == "--- a/Value.swift\n+++ b/Value.swift\n@@ -1 +1 @@\n-let value = 1\n+let value = 2\n\(added) Added.swift (+3 -0)\n")
            // The excerpt is the diff text trimmed, as the terminal writes it.
            #expect(try String(contentsOf: excerpt, encoding: .utf8) == channel.sessionDiffText()?.nilIfBlank)
            #expect(try Self.permissions(of: excerpt) == 0o600)
            #expect(try Self.permissions(of: staging) == 0o700)
            #expect(await transport.sentTexts.last == "Send the session diff as a document?")
            let body = try #require(await transport.sentBodies.last)
            let offerID = try #require(Self.consentOfferID(in: body))

            #expect(await channel.handleArtifactConsentCallback(
                TerminalTelegramArtifactConsentKeyboard.callbackPrefix + "cancel:" + offerID,
                message: Self.incoming(nil), lease: lease
            ))
            #expect(await transport.sentTexts.last == "ZenCODE message: file send cancelled.")
            #expect(!FileManager.default.fileExists(atPath: excerpt.path))
            await terminal.sessionHost.shutdown()
        }
    }

    /// A consent tap is claimed only for consent data; Send of an offer that
    /// does not exist, and Cancel, are answered with the terminal's texts.
    @Test
    func consentTapsAreAnswered() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            let message = Self.incoming(nil)

            #expect(!(await channel.handleArtifactConsentCallback(
                "zencode:mention:coordinator", message: message, lease: lease
            )))
            let prefix = TerminalTelegramArtifactConsentKeyboard.callbackPrefix
            for data in [prefix + "send:zencode-artifact-missing", prefix + "cancel:zencode-artifact-missing"] {
                #expect(await channel.handleArtifactConsentCallback(data, message: message, lease: lease))
            }
            #expect(Array(await transport.sentTexts.suffix(2)) == [
                "ZenCODE message: that confirmation expired or no longer matches the file. Ask again with /diff.",
                "ZenCODE message: file send cancelled.",
            ])
            await terminal.sessionHost.shutdown()
        }
    }

    /// An inbound attachment goes through the work seam first; one that
    /// cannot be received is answered with the terminal's text and leaves
    /// no temporary behind.
    @Test
    func inboundAttachmentsAreReceived() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            let attachment = TerminalTelegramInboundAttachment(
                fileID: "file-1", fileUniqueID: nil, kind: .document,
                mimeType: "text/plain", fileSize: 4, fileName: "note.txt", messageID: 3
            )
            let message = TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil, voice: nil, messageID: 3,
                chatTitle: "Test", username: "operator", attachment: attachment
            )
            let effects = TelegramTestRecorder<TelegramChannel.TelegramWorkEffectForTesting>()
            channel.onTelegramWorkEffectForTesting = { effect in
                effects.append(effect)
                return true
            }
            let sentBefore = await transport.sentTexts.count
            await channel.handleInboundAttachment(attachment, message: message, lease: lease)
            #expect(effects.values == [.attachmentDownload])
            #expect(await transport.sentTexts.count == sentBefore)

            channel.onTelegramWorkEffectForTesting = nil
            await channel.handleInboundAttachment(attachment, message: message, lease: lease)
            #expect(await transport.sentTexts.last == "ZenCODE message: the attachment could not be received.")
            #expect(await channel.controlService.inboundAttachmentFilenames(chatID: 42).isEmpty)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Support

    private struct HandLinked {
        let terminal: TerminalChat
        let channel: TelegramChannel
        let lease: TerminalTelegramRouteLease
        /// The channel's transport, which nothing should reach.
        let transport: TelegramChannelTestTransport
        let texts = TelegramTestRecorder<String>()
    }

    /// The Telegram channel of a terminal of session `room`, linked by hand
    /// to chat 42 on the route of `room`, its system messages recorded.
    private static func handLinked(room: String) async throws -> HandLinked {
        let transport = TelegramChannelTestTransport(botID: 1)
        let terminal = try Support.makeTerminal(transport: transport)
        terminal.sessionID = room
        let channel = terminal.telegramChannel
        let route = AgentTelegramRouteManifest(roomID: room, generation: 1)
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: room), generation: 1
        )
        await channel.router.refresh(linkedChatID: 42, ownerUserID: 7, routes: [route])
        channel.linkedChatID = 42
        channel.linkedUserID = 7
        channel.controlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active", botUsername: "zencode_bot",
            lastError: nil, lastMessagePreview: nil, wireLifecycleEpoch: UUID()
        )
        channel.activeRouteLease = lease
        let pair = HandLinked(terminal: terminal, channel: channel, lease: lease, transport: transport)
        let texts = pair.texts
        channel.onTelegramSystemMessage = { text, _ in
            texts.append(text)
            return true
        }
        return pair
    }

    /// A message of the owner in chat 42.
    private static func incoming(_ text: String?) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: 7, text: text, voice: nil, messageID: 77,
            chatTitle: "Test", username: "operator", replyToMessageID: nil
        )
    }

    /// A staging directory of the test's own, not created yet.
    private static func temporaryStagingDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-channel-artifacts-\(UUID().uuidString)", isDirectory: true
        )
    }

    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// The offer of the Send button in a `sendMessage` body.
    private static func consentOfferID(in body: String) -> String? {
        let marker = TerminalTelegramArtifactConsentKeyboard.callbackPrefix + "send:"
        guard let range = body.range(of: marker) else { return nil }
        let offerID = body[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return offerID.isEmpty ? nil : String(offerID)
    }
}
