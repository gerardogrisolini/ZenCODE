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
