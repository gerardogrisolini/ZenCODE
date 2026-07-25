//
//  TerminalVoiceTranscriptionRegistryTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Covers ownership, bounding, and cancellation of remote (Telegram) voice
/// transcriptions, which used to be unowned fire-and-forget tasks.
@Suite
struct TerminalVoiceTranscriptionRegistryTests {
    @Test
    func concurrentTranscriptionsAreBounded() {
        let registry = TerminalVoiceTranscriptionRegistry()
        let limit = TerminalVoiceTranscriptionRegistry.maximumConcurrentTranscriptions

        var slots: [UUID] = []
        for _ in 0..<limit {
            guard let slot = registry.reserveSlot() else {
                Issue.record("Expected a free transcription slot")
                return
            }
            slots.append(slot)
        }
        // A burst of voice notes is refused instead of starting unbounded
        // concurrent downloads and transcriptions.
        #expect(registry.reserveSlot() == nil)
        #expect(registry.activeCount == limit)

        registry.release(slots.removeFirst())
        #expect(registry.reserveSlot() != nil)
    }

    @Test
    func cancelAllCancelsInFlightTranscriptionsAndRefusesNewOnes() async {
        let registry = TerminalVoiceTranscriptionRegistry()
        guard let slot = registry.reserveSlot() else {
            Issue.record("Expected a free transcription slot")
            return
        }

        let didFinish = Mutex(false)
        let task = Task {
            defer { registry.release(slot) }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            didFinish.withLock { $0 = true }
        }
        registry.register(task, for: slot)

        registry.cancelAll()
        await task.value

        #expect(didFinish.withLock { $0 })
        #expect(registry.isShutDown)
        // After teardown no further work may be started.
        #expect(registry.reserveSlot() == nil)
        #expect(registry.activeCount == 0)
    }

    @Test
    func registeringAfterShutdownCancelsTheTaskImmediately() async {
        let registry = TerminalVoiceTranscriptionRegistry()
        guard let slot = registry.reserveSlot() else {
            Issue.record("Expected a free transcription slot")
            return
        }

        // Teardown races a transcription that has just been started.
        registry.cancelAll()

        let observedCancellation = Mutex(false)
        let task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            observedCancellation.withLock { $0 = true }
        }
        registry.register(task, for: slot)
        await task.value

        #expect(observedCancellation.withLock { $0 })
    }

    @Test
    func releasingAnUnknownSlotIsHarmless() {
        let registry = TerminalVoiceTranscriptionRegistry()
        registry.release(UUID())
        #expect(registry.activeCount == 0)
    }
}
