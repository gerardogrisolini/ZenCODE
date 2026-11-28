//
//  DictationVoiceAudioTests.swift
//  ZenCODECoreTests
//
//  The audio side of the dictation voice mode that needs no audio device:
//  grouping the configuration changes of one device change, limiting the
//  restarts after which the engine stops again, the echo-cancellation notice
//  after the device starts, and pausing a controller whose device never started.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Dictation voice audio")
struct DictationVoiceAudioTests {
    // MARK: - Device changes

    @Test
    func onlyTheLastChangeOfABurstProceeds() {
        var changes = VoiceChangeSettler()
        let first = changes.begin()
        let second = changes.begin()
        let third = changes.begin()
        #expect(!changes.isLatest(first))
        #expect(!changes.isLatest(second))
        #expect(changes.isLatest(third))
    }

    @Test
    func aChangeAfterASettledBurstProceedsOnItsOwn() {
        var changes = VoiceChangeSettler()
        let burst = changes.begin()
        #expect(changes.isLatest(burst))
        // Checking a change does not consume it.
        #expect(changes.isLatest(burst))
        let next = changes.begin()
        #expect(!changes.isLatest(burst))
        #expect(changes.isLatest(next))
    }

    // MARK: - Restart limit

    @Test
    func aRestartThatLeavesTheEngineRunningIsAnnouncedAndResetsTheCount() {
        var policy = VoiceAudioRestartPolicy()
        #expect(policy.restarted(isEngineRunning: true) == .announce)
        #expect(policy.consecutiveAudioRestarts == 0)
        // A restart that leaves the engine stopped counts, and a running one
        // clears the count again.
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.consecutiveAudioRestarts == 1)
        #expect(policy.restarted(isEngineRunning: true) == .announce)
        #expect(policy.consecutiveAudioRestarts == 0)
    }

    @Test
    func threeConsecutiveStoppedRestartsFail() {
        var policy = VoiceAudioRestartPolicy()
        #expect(VoiceAudioRestartPolicy.maximumConsecutiveAudioRestarts == 3)
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: false) == .fail)
        #expect(policy.consecutiveAudioRestarts == 3)
    }

    @Test
    func aRunningRestartStartsTheCountFromZeroAgain() {
        var policy = VoiceAudioRestartPolicy()
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: true) == .announce)
        // Two more stopped restarts are again below the limit; the third fails.
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: false) == .fail)
    }

    @Test
    func resettingTheCountStartsItFromZeroAgain() {
        var policy = VoiceAudioRestartPolicy()
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        policy.reset()
        #expect(policy == VoiceAudioRestartPolicy())
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: false) == .retry)
        #expect(policy.restarted(isEngineRunning: false) == .fail)
    }

    @Test
    func theRestartFailureMessageNamesTheStoppingEngineAndTheRetry() {
        #expect(DictationVoiceModeController.audioRestartFailedMessage
            == "ZenCODE: voice audio could not restart after the audio device changed: the audio engine keeps stopping. Run /voice on to retry.\n")
    }

    // MARK: - Echo cancellation

    @Test
    func echoCancellationIsReportedOnlyWhenItWasActiveAndIsNotNow() {
        let unavailable = DictationVoiceModeController.echoCancellationUnavailableMessage(
            outputDeviceName: "AirPlay"
        )
        #expect(DictationVoiceModeController.echoCancellationLossNotice(
            wasActive: true,
            isActive: false,
            outputDeviceName: "AirPlay"
        ) == unavailable)
        #expect(DictationVoiceModeController.echoCancellationLossNotice(
            wasActive: true,
            isActive: true,
            outputDeviceName: "AirPlay"
        ) == nil)
        // Already reported: neither a device that still lacks it nor one
        // that has it again is reported.
        #expect(DictationVoiceModeController.echoCancellationLossNotice(
            wasActive: false,
            isActive: false,
            outputDeviceName: "AirPlay"
        ) == nil)
        #expect(DictationVoiceModeController.echoCancellationLossNotice(
            wasActive: false,
            isActive: true,
            outputDeviceName: nil
        ) == nil)
    }

    @Test
    func theLossNoticeIsTheExistingMessageEvenWithoutAnOutputName() {
        #expect(DictationVoiceModeController.echoCancellationLossNotice(
            wasActive: true,
            isActive: false,
            outputDeviceName: nil
        ) == DictationVoiceModeController.echoCancellationUnavailableMessage(outputDeviceName: nil))
    }

    // MARK: - Pause

    /// A controller that is not listening has no device running: pausing and
    /// resuming change only its state, and resuming starts no audio.
    @Test
    func pausingAndResumingAControllerThatIsNotListeningStartsNoAudio() async {
        let log = CallbackLog()
        let controller = DictationVoiceModeController(
            languageCode: "it",
            locale: Locale(identifier: "it_IT"),
            callbacks: log.callbacks
        )
        #expect(await controller.setPaused(true))
        #expect(await controller.setPaused(true) == false)
        #expect(await controller.isPaused)
        #expect(await controller.setPaused(false))
        #expect(await controller.setPaused(false) == false)
        #expect(await controller.isPaused == false)
        #expect(await controller.isActive)
        #expect(await log.failures.isEmpty)
        #expect(await log.messages.isEmpty)
        await controller.stop()
        #expect(await controller.isActive == false)
        #expect(await log.failures.isEmpty)
    }
}

/// Records the messages a controller shows.
private actor CallbackLog {
    private(set) var messages: [String] = []
    private(set) var failures: [String] = []

    nonisolated var callbacks: VoiceModeCallbacks {
        VoiceModeCallbacks(
            systemMessage: { [self] text in
                await self.recordMessage(text)
            },
            failureMessage: { [self] text in
                await self.recordFailure(text)
            },
            utteranceRecognized: { _ in },
            dictationChanged: { _, _ in },
            speakingChanged: { _ in }
        )
    }

    private func recordMessage(_ text: String) {
        messages.append(text)
    }

    private func recordFailure(_ text: String) {
        failures.append(text)
    }
}
