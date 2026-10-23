//
//  TerminalVoiceModeTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Terminal voice mode")
struct TerminalVoiceModeTests {
    @Test
    func chunkerEmitsFortyMillisecondChunksAndKeepsTheRemainder() {
        #expect(TerminalVoicePCM.chunkByteCount == 1_920)
        var chunker = TerminalVoicePCMChunker()

        let firstChunks = chunker.append(Data(repeating: 1, count: 1_000))
        #expect(firstChunks.isEmpty)
        let chunks = chunker.append(Data(repeating: 2, count: 3_000))
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count == 1_920 })
        #expect(chunks[0].prefix(1_000).allSatisfy { $0 == 1 })
        #expect(chunks[0].suffix(920).allSatisfy { $0 == 2 })
        #expect(chunker.pendingByteCount == 4_000 - 3_840)

        chunker.reset()
        #expect(chunker.pendingByteCount == 0)
    }

    @Test
    func byteCountsConvertToPlayedMilliseconds() {
        #expect(TerminalVoicePCM.milliseconds(forByteCount: 4_800) == 100)
        #expect(TerminalVoicePCM.milliseconds(forByteCount: 1_920) == 40)
        #expect(TerminalVoicePCM.milliseconds(forByteCount: 47) == 0)
        #expect(TerminalVoicePCM.milliseconds(forByteCount: -10) == 0)
        #expect(TerminalVoicePCM.milliseconds(forByteCount: OpenAIRealtimeSession.bytesPerMillisecond) == 1)
    }

    @Test
    func littleEndianPCM16BecomesNormalisedFloatSamples() {
        // 0x0000, 0x4000 (16 384), 0x8000 (-32 768), 0x7FFF, then a stray byte.
        let data = Data([0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0xFF, 0x7F, 0x12])
        let samples = TerminalVoicePCM.floatSamples(fromPCM16: data)
        #expect(samples.count == 4)
        #expect(samples[0] == 0)
        #expect(samples[1] == 0.5)
        #expect(samples[2] == -1)
        #expect(abs(samples[3] - Float(32_767) / 32_768) < 0.000_001)
        #expect(TerminalVoicePCM.floatSamples(fromPCM16: Data([0x01])).isEmpty)
    }

    @Test
    func floatSamplesEncodeToClampedLittleEndianPCM16() {
        let data = TerminalVoicePCM.pcm16Data(fromFloatSamples: [0, 0.5, -1, 2, -.infinity, .nan])
        #expect(Array(data) == [
            0x00, 0x00,
            0x00, 0x40,
            0x01, 0x80,
            0xFF, 0x7F,
            0x00, 0x00,
            0x00, 0x00
        ])
        let roundTrip = TerminalVoicePCM.floatSamples(fromPCM16: TerminalVoicePCM.pcm16Data(fromFloatSamples: [0.25, -0.25]))
        #expect(abs(roundTrip[0] - 0.25) < 0.001)
        #expect(abs(roundTrip[1] + 0.25) < 0.001)
        #expect(TerminalVoicePCM.milliseconds(forFrameCount: 2_400) == 100)
    }

    @Test
    func chunkEncoderEmitsFortyMillisecondPCM16Chunks() {
        let encoder = TerminalVoicePCM16ChunkEncoder()
        #expect(encoder.encode([Float](repeating: 0.1, count: 500)).isEmpty)
        let chunks = encoder.encode([Float](repeating: 0.1, count: 1_500))
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count == TerminalVoicePCM.chunkByteCount })
        encoder.reset()
        #expect(encoder.encode([Float](repeating: 0.1, count: 959)).isEmpty)
    }

    @Test
    func playbackLedgerAccumulatesPerItemAndResets() {
        var ledger = TerminalVoicePlaybackLedger()
        let first = ledger.recordPlayed(itemID: "item_a", milliseconds: 40)
        let second = ledger.recordPlayed(itemID: "item_a", milliseconds: 60)
        let otherItem = ledger.recordPlayed(itemID: "item_b", milliseconds: 20)
        ledger.reset()
        let afterReset = ledger.recordPlayed(itemID: "item_b", milliseconds: 10)
        #expect(first == 40)
        #expect(second == 100)
        #expect(otherItem == 20)
        #expect(afterReset == 10)
    }

    @Test
    func aVoiceMarkerIsNotQueuedBehindAnotherMarker() {
        let marker = OpenAIRealtimeVoiceTurn.promptMarker
        var queue = TerminalQueuedPromptBuffer()
        #expect(!queue.isRedundantVoiceTurnMarker(marker))

        let queuedMarker = queue.enqueue(TerminalQueuedPrompt(text: marker, origin: .local, mode: .directPrompt))
        #expect(queuedMarker)
        #expect(queue.isRedundantVoiceTurnMarker(marker))
        #expect(!queue.isRedundantVoiceTurnMarker("typed prompt"))

        let queuedTypedPrompt = queue.enqueue(TerminalQueuedPrompt(text: "typed prompt", origin: .local))
        #expect(queuedTypedPrompt)
        #expect(!queue.isRedundantVoiceTurnMarker(marker))
    }

    @Test
    func reconnectDelayDoublesUpToTwoSeconds() {
        var delay = TerminalVoiceSessionController.initialReconnectDelay
        var delays: [Duration] = [delay]
        for _ in 0..<6 {
            delay = TerminalVoiceSessionController.nextReconnectDelay(after: delay)
            delays.append(delay)
        }
        #expect(delays == [
            .milliseconds(50), .milliseconds(100), .milliseconds(200), .milliseconds(400),
            .milliseconds(800), .milliseconds(1_600), .seconds(2)
        ])
        #expect(TerminalVoiceSessionController.maximumReconnectAttempts == 5)
    }

    @Test
    func voiceCommandIsKnownAndUsableDuringGeneration() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)
        #expect(commands.contains("/voice"))
        #expect(TerminalChat.isKnownSlashCommand("/voice"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/voice"))
        #expect(
            TerminalVoiceSessionController.listeningMessage(modelID: "gpt-realtime-2.1")
                == "Voice: listening (gpt-realtime-2.1). /voice pauses the microphone.\n"
        )
    }

    @Test
    func echoCancellationWarningNamesTheCurrentOutput() {
        #expect(
            TerminalVoiceSessionController.echoCancellationUnavailableMessage(outputDeviceName: "AirPlay")
                == "Voice: echo cancellation is unavailable with the current audio output (AirPlay); switch to a local output or use headphones so you can talk over the assistant without it hearing itself.\n"
        )
        #expect(
            TerminalVoiceSessionController.echoCancellationUnavailableMessage(outputDeviceName: nil)
                == "Voice: echo cancellation is unavailable with the current audio output; switch to a local output or use headphones so you can talk over the assistant without it hearing itself.\n"
        )
    }
}
