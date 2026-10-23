//
//  TerminalChat+Voice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//

import Foundation
import Synchronization

/// The session, agent and manual model selection last evaluated for voice
/// mode. Any change re-evaluates whether the active model is a realtime one.
struct TerminalVoiceActivationKey: Equatable, Sendable {
    let sessionID: String
    let agentID: String?
    let manualModelID: String?
}

/// The voice link currently fed by the audio tasks.
private final class TerminalVoiceLinkHolder: Sendable {
    private let link = Mutex<OpenAIRealtimeVoiceLink?>(nil)

    var current: OpenAIRealtimeVoiceLink? {
        link.withLock { $0 }
    }

    func set(_ newValue: OpenAIRealtimeVoiceLink?) {
        link.withLock { $0 = newValue }
    }
}

private struct TerminalVoicePlaybackReport: Sendable {
    let itemID: String
    let milliseconds: Int
}

/// Owns the realtime voice loop of one interactive terminal: microphone
/// permission, audio I/O and the voice link. Audio and transcripts handled
/// here are never persisted.
actor TerminalVoiceSessionController {
    struct Callbacks: Sendable {
        let acquireLink: @Sendable () async throws -> OpenAIRealtimeVoiceLink?
        let systemMessage: @Sendable (String) async -> Void
        let failureMessage: @Sendable (String) async -> Void
        let voiceTurnCommitted: @Sendable () -> Void
    }

    enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case listening
        /// The backend retired the link (session reset, agent or model
        /// switch); the terminal re-attaches once it re-evaluates voice mode.
        case detached
        case failed
        case stopped
    }

    enum MicrophoneToggle: Sendable, Equatable {
        case paused
        case resumed
        case restarting
    }

    static let maximumReconnectAttempts = 5
    static let initialReconnectDelay = Duration.milliseconds(50)
    static let maximumReconnectDelay = Duration.seconds(2)
    /// About one second of 40 ms chunks; older chunks are dropped first.
    private static let capturedChunkBacklog = 25

    private let callbacks: Callbacks
    private let device = TerminalVoiceAudioDevice()
    private let linkHolder = TerminalVoiceLinkHolder()
    private(set) var phase: Phase = .idle
    private(set) var isMicrophonePaused = false
    private var isAudioRunning = false
    private var linkTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var playbackReportTask: Task<Void, Never>?
    private var captureContinuation: AsyncStream<Data>.Continuation?
    private var playbackReportContinuation: AsyncStream<TerminalVoicePlaybackReport>.Continuation?

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    static func listeningMessage(modelID: String) -> String {
        "Voice: listening (\(modelID)). /voice pauses the microphone.\n"
    }

    static let microphoneDeniedMessage = "ZenCODE: microphone access is not granted. Allow your terminal app under System Settings > Privacy & Security > Microphone, then run /voice.\n"

    /// Shown when the voice device runs without echo cancellation because the
    /// current output cannot run voice processing.
    static func echoCancellationUnavailableMessage(outputDeviceName: String?) -> String {
        let output = outputDeviceName.map { "the current audio output (\($0))" }
            ?? "the current audio output"
        return "Voice: echo cancellation is unavailable with \(output); switch to a local output or use headphones so you can talk over the assistant without it hearing itself.\n"
    }

    func start() async {
        guard phase == .idle || phase == .failed else {
            return
        }
        phase = .connecting
        guard TerminalVoiceAudioDevice.isSupported else {
            phase = .failed
            await callbacks.failureMessage(
                "ZenCODE: \(TerminalVoiceAudioError.unsupportedPlatform.localizedDescription)\n"
            )
            return
        }
        guard await TerminalVoiceAudioDevice.requestMicrophoneAccess() else {
            phase = .failed
            await callbacks.failureMessage(Self.microphoneDeniedMessage)
            return
        }
        guard phase == .connecting else {
            return
        }
        if !isAudioRunning {
            do {
                let hasEchoCancellation = try startAudio()
                if !hasEchoCancellation {
                    await callbacks.systemMessage(Self.echoCancellationUnavailableMessage(
                        outputDeviceName: device.outputDeviceName
                    ))
                }
            } catch {
                phase = .failed
                await callbacks.failureMessage(
                    "ZenCODE: voice audio could not start: \(error.localizedDescription)\n"
                )
                return
            }
        }
        startLinkLoop()
    }

    func reattachIfDetached() {
        guard phase == .detached else {
            return
        }
        phase = .connecting
        startLinkLoop()
    }

    /// Re-acquires the link for the terminal's current session, e.g. after
    /// `/new` or an agent switch that kept a realtime model.
    func reattach() {
        switch phase {
        case .connecting, .listening, .detached:
            phase = .connecting
            startLinkLoop()
        case .idle, .failed, .stopped:
            return
        }
    }

    func toggleMicrophone() async -> MicrophoneToggle {
        if phase == .failed {
            await start()
            return .restarting
        }
        let paused = !isMicrophonePaused
        if isAudioRunning {
            device.setCapturePaused(paused)
        }
        isMicrophonePaused = paused
        return paused ? .paused : .resumed
    }

    /// Stops assistant audio that is still playing, e.g. after Esc.
    func interruptPlayback() {
        device.interruptPlayback()
    }

    func stop() {
        phase = .stopped
        linkTask?.cancel()
        linkTask = nil
        linkHolder.set(nil)
        captureContinuation?.finish()
        captureContinuation = nil
        playbackReportContinuation?.finish()
        playbackReportContinuation = nil
        captureTask?.cancel()
        captureTask = nil
        playbackReportTask?.cancel()
        playbackReportTask = nil
        if isAudioRunning {
            device.stop()
            isAudioRunning = false
        }
    }

    // MARK: - Audio

    private func startAudio() throws -> Bool {
        let (captured, captureContinuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(Self.capturedChunkBacklog)
        )
        let (reports, reportContinuation) = AsyncStream.makeStream(
            of: TerminalVoicePlaybackReport.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let encoder = TerminalVoicePCM16ChunkEncoder()
        let hasEchoCancellation = try device.start(
            capturePaused: isMicrophonePaused,
            onSamples: { samples in
                for chunk in encoder.encode(samples) {
                    captureContinuation.yield(chunk)
                }
            }
        )
        isAudioRunning = true
        self.captureContinuation = captureContinuation
        playbackReportContinuation = reportContinuation
        let holder = linkHolder
        captureTask = Task.detached(name: "ZenCODE.TUI.voice-capture") {
            for await chunk in captured {
                await holder.current?.appendInputAudio(chunk)
            }
        }
        playbackReportTask = Task.detached(name: "ZenCODE.TUI.voice-playback-reports") {
            var ledger = TerminalVoicePlaybackLedger()
            for await report in reports {
                let played = ledger.recordPlayed(
                    itemID: report.itemID,
                    milliseconds: report.milliseconds
                )
                await holder.current?.reportPlayback(
                    itemID: report.itemID,
                    playedMilliseconds: played
                )
            }
        }
        return hasEchoCancellation
    }

    private func enqueueAssistantAudio(_ audio: Data, itemID: String) {
        let report = TerminalVoicePlaybackReport(
            itemID: itemID,
            milliseconds: TerminalVoicePCM.milliseconds(forByteCount: audio.count)
        )
        let reports = playbackReportContinuation
        device.enqueuePlayback(TerminalVoicePCM.floatSamples(fromPCM16: audio)) {
            reports?.yield(report)
        }
    }

    // MARK: - Link

    private func startLinkLoop() {
        linkTask?.cancel()
        linkTask = Task(name: "ZenCODE.TUI.voice-link") {
            await self.runLinkLoop()
        }
    }

    private func runLinkLoop() async {
        var failures = 0
        var delay = Self.initialReconnectDelay

        while !Task.isCancelled {
            let link: OpenAIRealtimeVoiceLink?
            do {
                link = try await callbacks.acquireLink()
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                failures += 1
                guard failures < Self.maximumReconnectAttempts else {
                    await fail("ZenCODE: voice mode stopped: \(error.localizedDescription) Run /voice to retry.\n")
                    return
                }
                try? await Task.sleep(for: delay)
                delay = Self.nextReconnectDelay(after: delay)
                continue
            }
            guard !Task.isCancelled else {
                return
            }
            guard let link else {
                // The active backend is not a realtime backend any more.
                phase = .detached
                return
            }

            linkHolder.set(link)
            var disconnectReason: String?
            for await event in link.events {
                switch event {
                case .connected:
                    failures = 0
                    delay = Self.initialReconnectDelay
                    if phase != .listening {
                        phase = .listening
                        await callbacks.systemMessage(Self.listeningMessage(modelID: link.modelID))
                    }
                case let .disconnected(reason):
                    disconnectReason = reason
                case .turnCommitted:
                    callbacks.voiceTurnCommitted()
                case let .audio(audio, itemID, _):
                    enqueueAssistantAudio(audio, itemID: itemID)
                case .interruptPlayback:
                    device.interruptPlayback()
                case .speechStarted, .speechStopped:
                    break
                }
                if disconnectReason != nil || Task.isCancelled {
                    break
                }
            }
            // A cancelled loop was superseded or stopped; its successor (or
            // `stop`) owns the link holder from here on.
            guard !Task.isCancelled else {
                return
            }
            linkHolder.set(nil)
            device.interruptPlayback()
            guard let disconnectReason else {
                phase = .detached
                return
            }
            failures += 1
            guard failures <= Self.maximumReconnectAttempts else {
                await fail("ZenCODE: voice connection lost (\(disconnectReason)). Run /voice to retry.\n")
                return
            }
            phase = .connecting
            await callbacks.systemMessage("Voice: connection lost (\(disconnectReason)). Reconnecting...\n")
            try? await Task.sleep(for: delay)
            delay = Self.nextReconnectDelay(after: delay)
        }
    }

    /// Doubles the reconnect delay up to `maximumReconnectDelay`.
    static func nextReconnectDelay(after delay: Duration) -> Duration {
        min(delay * 2, maximumReconnectDelay)
    }

    private func fail(_ message: String) async {
        phase = .failed
        linkHolder.set(nil)
        await callbacks.failureMessage(message)
    }
}

extension TerminalChat {
    /// Whether the effective model of the active agent is an OpenAI realtime
    /// voice model.
    func isRealtimeVoiceModelActive() -> Bool {
        guard let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: currentEffectiveModelID()
        ),
            let provider = selection.remoteProvider else {
            return false
        }
        return OpenAIRealtimeModel.matches(provider: provider, modelID: selection.modelID)
    }

    /// Voice mode belongs to the built-in Organizer profile, matched by its
    /// stable ID so a renamed copy does not inherit it.
    func isOrganizerAgentActive() -> Bool {
        guard let agentID = selectedAgent?.id.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return agentID.caseInsensitiveCompare(AgentProfileStore.organizerAgentID.uuidString) == .orderedSame
    }

    func currentVoiceMode() -> TerminalVoiceMode {
        guard isOrganizerAgentActive() else {
            return .off
        }
        return TerminalVoiceMode.resolve(
            isOrganizer: true,
            isRealtimeModel: isRealtimeVoiceModelActive()
        )
    }

    /// Starts, stops, switches or re-attaches voice mode after anything that
    /// may have changed the session, the agent or the model. Cheap when
    /// nothing changed.
    func reevaluateVoiceMode(eventQueue: TerminalChatEventQueue) async {
        let key = TerminalVoiceActivationKey(
            sessionID: sessionID,
            agentID: selectedAgent?.id,
            manualModelID: manualModelIDOverride
        )
        if key == voiceActivationKey {
            await realtimeVoiceController?.reattachIfDetached()
            return
        }
        voiceActivationKey = key

        switch currentVoiceMode() {
        case .off:
            await stopRealtimeVoice()
            await stopDictationVoice()
        case .realtime:
            await stopDictationVoice()
            if let controller = realtimeVoiceController {
                await controller.reattach()
                return
            }
            let controller = TerminalVoiceSessionController(
                callbacks: realtimeVoiceCallbacks(eventQueue: eventQueue)
            )
            realtimeVoiceController = controller
            // Starting may wait on the system microphone prompt; never hold
            // the terminal event loop on it.
            Task(name: "ZenCODE.TUI.voice-start") {
                await controller.start()
            }
        case .dictation:
            await stopRealtimeVoice()
            // Dictation does not depend on the session, so a session change
            // keeps the running controller.
            guard dictationVoiceController == nil else {
                return
            }
            let manifest = AgentSettingsManifestStore.load()
            let languageCode = TerminalVoiceLanguage.resolvedCode(
                voiceLanguage: manifest?.voice?.language,
                responseLanguage: manifest?.responseLanguage,
                systemLanguage: ResponseLanguageResolver.systemLanguageCode()
            )
            let controller = TerminalDictationVoiceController(
                languageCode: languageCode,
                locale: AgentVoiceTranscriptionService.locale(for: languageCode),
                callbacks: dictationVoiceCallbacks(eventQueue: eventQueue)
            )
            dictationVoiceController = controller
            Task(name: "ZenCODE.TUI.dictation-start") {
                await controller.start()
            }
        }
    }

    func stopRealtimeVoice() async {
        guard let controller = realtimeVoiceController else {
            return
        }
        realtimeVoiceController = nil
        await controller.stop()
    }

    func stopDictationVoice() async {
        guard let controller = dictationVoiceController else {
            return
        }
        dictationVoiceController = nil
        await controller.stop()
    }

    func stopVoiceMode() async {
        await stopRealtimeVoice()
        await stopDictationVoice()
        voiceActivationKey = nil
    }

    /// Reads a completed answer aloud in dictation mode. The realtime mode
    /// speaks through the provider instead.
    func speakVoiceResponse(_ response: String) async {
        await dictationVoiceController?.speak(response)
    }

    /// Stops assistant audio that is still playing, e.g. after Esc.
    func interruptVoicePlayback() async {
        await realtimeVoiceController?.interruptPlayback()
        await dictationVoiceController?.interruptPlayback()
    }

    func handleVoiceCommand(_ command: String) async {
        let arguments = Self.slashCommandArguments(from: command, commandPrefix: "/voice")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard arguments.isEmpty else {
            await writeFailureMessage("ZenCODE: /voice does not accept arguments.\n")
            return
        }
        let toggle: TerminalVoiceSessionController.MicrophoneToggle
        if let controller = realtimeVoiceController {
            toggle = await controller.toggleMicrophone()
        } else if let controller = dictationVoiceController {
            toggle = await controller.toggleMicrophone()
        } else {
            await writeFailureMessage(
                "ZenCODE: /voice is available only with the Organizer agent in the interactive terminal on macOS.\n"
            )
            return
        }
        switch toggle {
        case .paused:
            await writeSystemMessage("Voice: microphone paused. /voice resumes it.\n")
        case .resumed:
            await writeSystemMessage("Voice: microphone resumed.\n")
        case .restarting:
            break
        }
    }

    private func realtimeVoiceCallbacks(
        eventQueue: TerminalChatEventQueue
    ) -> TerminalVoiceSessionController.Callbacks {
        let runner = sessionRunner
        return TerminalVoiceSessionController.Callbacks(
            acquireLink: { [weak self] in
                guard let configuration = await self?.currentSessionConfiguration() else {
                    return nil
                }
                return try await runner.realtimeVoiceLink(configuration: configuration)
            },
            systemMessage: { [weak self] text in
                await self?.writeSystemMessage(text)
            },
            failureMessage: { [weak self] text in
                await self?.writeFailureMessage(text)
            },
            voiceTurnCommitted: {
                _ = eventQueue.offer(.voicePromptCompleted(
                    TerminalVoicePromptResult(
                        origin: .local,
                        outcome: .success(OpenAIRealtimeVoiceTurn.promptMarker)
                    )
                ))
            }
        )
    }

    private func dictationVoiceCallbacks(
        eventQueue: TerminalChatEventQueue
    ) -> TerminalDictationVoiceController.Callbacks {
        TerminalDictationVoiceController.Callbacks(
            systemMessage: { [weak self] text in
                await self?.writeSystemMessage(text)
            },
            failureMessage: { [weak self] text in
                await self?.writeFailureMessage(text)
            },
            utteranceRecognized: { utterance in
                _ = await eventQueue.sendWithBackpressure(
                    Self.dictatedPromptEvent(for: utterance)
                )
            }
        )
    }

    /// A dictated utterance is handled like a typed line, so it also answers
    /// a pending plan or workflow question and queues while a turn runs. Text
    /// that would read as a slash command is always sent as a plain prompt.
    nonisolated static func dictatedPromptEvent(for utterance: String) -> TerminalChatRuntimeEvent {
        if utterance.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return .voicePromptCompleted(
                TerminalVoicePromptResult(origin: .local, outcome: .success(utterance))
            )
        }
        return .input(.submitted(utterance))
    }
}
