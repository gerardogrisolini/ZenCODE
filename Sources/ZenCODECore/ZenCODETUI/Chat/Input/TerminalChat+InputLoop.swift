//
//  TerminalChat+InputLoop.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

extension TerminalChat {
    func synchronizeLocalExecAccessModeStatusBar() async {
        let accessMode = await sessionRunner.localExecAccessMode()
        await statusBar.update(localExecAccessMode: accessMode)
    }

    /// Routes consent prompts through the terminal's single interactive reader.
    /// The live input panel is suspended around each read so its loop cannot
    /// consume or contend for the operator's keystroke (no second terminal
    /// input device), then resumed. Reading runs off the cooperative executor
    /// so the authorizer actor is not blocked while the operator decides.
    func configureConsentReader(eventQueue: TerminalChatEventQueue) async {
        await permissionAuthorizer.setConsentReader({ [interactiveReader, statusBar, weak self] prompt in
            await interactiveReader.stopPanelInput(clearPanel: false)
            let answer = await Self.readConsentKeyOffActor(
                reader: interactiveReader,
                prompt: prompt
            )
            // `readSingleKey` terminates the echoed choice with one newline.
            // Add another before restoring the panel so its first rendered row
            // cannot overlap or clip the authorization card's bottom border.
            AgentOutput.standardError.writeString("\n")
            let suggestions = self?.commandSuggestionsForCurrentAgent() ?? []
            _ = await interactiveReader.resumePanelInput(
                statusBar: statusBar,
                commandSuggestions: suggestions,
                onEvent: { event in eventQueue.send(.input(event)) }
            )
            return answer
        })
    }

    static func readConsentKeyOffActor(
        reader: TerminalInteractiveLineReader,
        prompt: String
    ) async -> String? {
        let cancellation = ConsentReadCancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(
                        returning: reader.readSingleKey(
                            prompt: prompt,
                            shouldCancel: cancellation.isCancelled
                        )
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func runBlockingInputLoop(initialInputLine: String?) async throws {
        var pendingInputLine = initialInputLine
        while true {
            let promptInput: String
            if stdinIsTerminal {
                guard let line = interactiveReader.readLine(prompt: "> ") else {
                    break
                }
                promptInput = line
            } else {
                guard let line = pendingInputLine ?? reader.readLine() else {
                    break
                }
                pendingInputLine = nil
                let pastedLines = reader.drainBufferedLines(waitMilliseconds: 80)
                promptInput = ([line] + pastedLines).joined(separator: "\n")
            }

            if activeVoiceRecordingSession != nil {
                await stopVoiceRecordingAndRunPromptBlocking()
                continue
            }

            switch await submittedLineAction(promptInput) {
            case .continueChat:
                continue
            case .exitChat:
                return
            case let .runPrompt(prompt):
                await runPromptBlocking(promptAttempt(prompt: prompt))
            case let .runHiddenPrompt(prompt, purpose):
                await runPromptBlocking(
                    promptAttempt(prompt: prompt, isUserVisible: false, purpose: purpose)
                )
            case let .prefillPrompt(prompt):
                await writeSystemMessage("Draft prompt:\n\(prompt)\n")
            }
        }
    }

    func runInteractivePanelLoop() async throws {
        let eventQueue = TerminalChatEventQueue()
        var queuedPrompts: [TerminalQueuedPrompt] = []
        var generationTask: Task<Void, Never>?
        var voiceTranscriptionTask: Task<Void, Never>?
        let telegramForwardingTask = startTelegramForwardingTask(eventQueue: eventQueue)
        var isGenerating = false
        var isQueuedPromptStartScheduled = false

        func scheduleQueuedPromptIfNeeded() {
            guard !isGenerating,
                  !queuedPrompts.isEmpty,
                  !isQueuedPromptStartScheduled else {
                return
            }
            isQueuedPromptStartScheduled = true
            eventQueue.send(.startNextQueuedPrompt)
        }

        @discardableResult
        func startPanelInput() async -> Bool {
            let didStart = await interactiveReader.startPanelInput(
                statusBar: statusBar,
                commandSuggestions: commandSuggestionsForCurrentAgent()
            ) { event in
                eventQueue.send(.input(event))
            }
            guard didStart else {
                return false
            }
            await interactiveReader.setPanelProcessing(isGenerating)
            await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
            return true
        }

        func stopPanelInput(clearPanel: Bool = true) async {
            await interactiveReader.stopPanelInput(clearPanel: clearPanel)
        }

        func startGeneration(attempt: TerminalPromptAttempt) async {
            isGenerating = true
            didReceiveMetricsForCurrentPrompt = false
            didRefreshGitStatusDuringCurrentPrompt = false
            await statusBar.beginRequest()
            await statusBar.setProcessing(true)
            await interactiveReader.setPanelProcessing(true)
            generationTask = Task {
                let result: TerminalChatGenerationResult
                do {
                    result = .success(try await self.generateResponse(attempt: attempt))
                } catch is CancellationError {
                    result = .failure(
                        TerminalChatGenerationFailure(
                            message: "",
                            isCancellation: true,
                            origin: attempt.origin,
                            fileChangeSummary: nil
                        )
                    )
                } catch {
                    let failure = TerminalChatGenerationFailure(
                        error: error,
                        origin: attempt.origin
                    )
                    result = .failure(
                        failure
                    )
                }
                eventQueue.send(.generationCompleted(result))
            }
        }

        func startDirectPrompt(_ prompt: String, origin: TerminalPromptOrigin) async {
            let attempt = promptAttempt(prompt: prompt, origin: origin)
            if origin == .local {
                await writeSubmittedPrompt(prompt)
            } else {
                await writeTelegramSubmittedPrompt(prompt)
            }
            await startGeneration(attempt: attempt)
        }

        await synchronizeLocalExecAccessModeStatusBar()

        await configureConsentReader(eventQueue: eventQueue)

        guard await startPanelInput() else {
            await statusBar.stop()
            throw TerminalChatError.interactivePromptUnavailable
        }
        defer {
            generationTask?.cancel()
            voiceTranscriptionTask?.cancel()
            voiceRecordingService.cancelRecording()
            telegramForwardingTask.cancel()
        }

        func handleSubmittedPanelLine(
            _ line: String,
            origin: TerminalPromptOrigin = .local
        ) async -> Bool {
            let shouldSuspendPanel = origin == .local && Self.shouldSuspendPanelInput(for: line)
            if shouldSuspendPanel {
                await stopPanelInput(clearPanel: false)
                await renderCoordinator.setOverviewPublishingSuspended(true)
            }

            let action = await submittedLineAction(line, origin: origin)
            if shouldSuspendPanel {
                await renderCoordinator.setOverviewPublishingSuspended(false)
            }

            switch action {
            case .continueChat:
                if shouldSuspendPanel {
                    _ = await startPanelInput()
                }
                return true
            case .exitChat:
                generationTask?.cancel()
                return false
            case let .runPrompt(prompt):
                if shouldSuspendPanel {
                    _ = await startPanelInput()
                }
                let attempt = promptAttempt(prompt: prompt, origin: origin)
                if origin == .local {
                    await writeSubmittedPrompt(prompt)
                } else {
                    await writeTelegramSubmittedPrompt(prompt)
                }
                await startGeneration(attempt: attempt)
                return true
            case let .runHiddenPrompt(prompt, purpose):
                if shouldSuspendPanel {
                    _ = await startPanelInput()
                }
                await startGeneration(
                    attempt: promptAttempt(
                        prompt: prompt,
                        origin: origin,
                        isUserVisible: false,
                        purpose: purpose
                    )
                )
                return true
            case let .prefillPrompt(prompt):
                if shouldSuspendPanel {
                    _ = await startPanelInput()
                }
                await interactiveReader.setPanelText(prompt)
                return true
            }
        }

        eventLoop: for await event in eventQueue.events {
            switch event {
            case let .input(inputEvent):
                switch inputEvent {
                case let .submitted(line):
                    if activeVoiceRecordingSession != nil {
                        voiceTranscriptionTask = await stopVoiceRecordingAndTranscribe(
                            eventQueue: eventQueue
                        )
                        continue
                    }

                    if !isGenerating, !queuedPrompts.isEmpty {
                        queuedPrompts.append(TerminalQueuedPrompt(text: line, origin: .local))
                        await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                        scheduleQueuedPromptIfNeeded()
                        continue
                    }

                    if isGenerating {
                        switch Self.submittedLineRole(for: line) {
                        case .empty, .prompt:
                            queuedPrompts.append(TerminalQueuedPrompt(text: line, origin: .local))
                            await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                            continue
                        case .slashCommand:
                            if Self.isAvailableDuringGeneration(for: line) {
                                break
                            }
                            await writeFailureMessage(generatingSlashCommandMessage(for: line))
                            continue
                        }
                    }

                    guard await handleSubmittedPanelLine(line) else {
                        break eventLoop
                    }
                case .cancelRequested:
                    if activeVoiceRecordingSession != nil {
                        await cancelVoiceRecording()
                    } else if voiceTranscriptionTask != nil {
                        voiceTranscriptionTask?.cancel()
                        voiceTranscriptionTask = nil
                        await clearVoicePanelMode()
                        await writeSystemMessage("Voice transcription cancelled.\n")
                    } else {
                        generationTask?.cancel()
                    }
                case .toggleToolDetailsRequested:
                    await self.toggleToolDetailsOutput()
                    await interactiveReader.refreshPanel()
                case .toggleAccessModeRequested:
                    let accessMode = await sessionRunner.toggleLocalExecAccessMode()
                    await statusBar.update(localExecAccessMode: accessMode)
                    await writeAccessModeChangeMessage(accessMode)
                    await interactiveReader.refreshPanel()
                case .endOfInput:
                    generationTask?.cancel()
                    break eventLoop
                }
            case let .generationCompleted(result):
                generationTask = nil
                isGenerating = false
                await statusBar.setProcessing(false)
                await interactiveReader.setPanelProcessing(false)
                await finishPromptResult(result)
                await refreshStatusBarGitStatusSummaryAfterPromptIfNeeded()
                scheduleQueuedPromptIfNeeded()
            case .startNextQueuedPrompt:
                isQueuedPromptStartScheduled = false
                guard !isGenerating, !queuedPrompts.isEmpty else {
                    continue
                }
                let nextPrompt = queuedPrompts.removeFirst()
                await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                if nextPrompt.mode == .directPrompt {
                    await startDirectPrompt(nextPrompt.text, origin: nextPrompt.origin)
                    continue
                }
                guard await handleSubmittedPanelLine(
                    nextPrompt.text,
                    origin: nextPrompt.origin
                ) else {
                    break eventLoop
                }
                scheduleQueuedPromptIfNeeded()
            case let .telegramMessage(message):
                await handleTelegramMessage(
                    message,
                    isGenerating: isGenerating,
                    queuedPrompts: &queuedPrompts,
                    eventQueue: eventQueue
                )
                await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                scheduleQueuedPromptIfNeeded()
            case let .voicePromptProgress(progress):
                if progress.origin == .local {
                    await interactiveReader.setPanelOverlay(
                        TerminalPanelModeOverride(
                            modeText: "Transcribing voice",
                            helpText: progress.message
                        ),
                        isProcessing: true
                    )
                }
                await sendTelegramSystemMessageIfLinked(
                    "Voice: \(progress.message)",
                    origin: progress.origin
                )
            case let .voicePromptCompleted(result):
                if result.origin == .local {
                    voiceTranscriptionTask = nil
                    await clearVoicePanelMode()
                    await interactiveReader.setPanelProcessing(isGenerating)
                }
                switch result.outcome {
                case let .success(prompt):
                    if isGenerating || !queuedPrompts.isEmpty {
                        queuedPrompts.append(
                            TerminalQueuedPrompt(
                                text: prompt,
                                origin: result.origin,
                                mode: .directPrompt
                            )
                        )
                        await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                        scheduleQueuedPromptIfNeeded()
                        await sendTelegramSystemMessageIfLinked(
                            "Transcription ready. Queued for the current ZenCODE session.",
                            origin: result.origin
                        )
                    } else {
                        await sendTelegramSystemMessageIfLinked(
                            "Transcription ready. ZenCODE is working.",
                            origin: result.origin
                        )
                        await startDirectPrompt(prompt, origin: result.origin)
                    }
                case let .failure(message):
                    await writeFailureMessage("ZenCODE: \(message)\n")
                    await sendTelegramSystemMessageIfLinked(
                        "Voice transcription failed: \(message)",
                        origin: result.origin
                    )
                }
            }
        }

        await stopPanelInput()
    }
}
