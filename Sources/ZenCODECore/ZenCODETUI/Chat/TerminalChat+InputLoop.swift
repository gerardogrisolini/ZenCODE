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
                writeSystemMessage("Draft prompt:\n\(prompt)\n")
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

        @discardableResult
        func startPanelInput() -> Bool {
            let didStart = interactiveReader.startPanelInput(
                statusBar: statusBar,
                commandSuggestions: commandSuggestionsForCurrentAgent()
            ) { event in
                Task {
                    await eventQueue.send(.input(event))
                }
            }
            guard didStart else {
                return false
            }
            interactiveReader.setPanelProcessing(isGenerating)
            interactiveReader.setQueuedPromptCount(queuedPrompts.count)
            return true
        }

        func stopPanelInput(clearPanel: Bool = true) async {
            await interactiveReader.stopPanelInput(clearPanel: clearPanel)
        }

        func startGeneration(attempt: TerminalPromptAttempt) {
            isGenerating = true
            didReceiveMetricsForCurrentPrompt = false
            didRefreshGitStatusDuringCurrentPrompt = false
            statusBar.beginRequest()
            statusBar.setProcessing(true)
            interactiveReader.setPanelProcessing(true)
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
                await eventQueue.send(.generationCompleted(result))
            }
        }

        func startDirectPrompt(_ prompt: String, origin: TerminalPromptOrigin) {
            let attempt = promptAttempt(prompt: prompt, origin: origin)
            if origin == .local {
                writeSubmittedPrompt(prompt)
            } else {
                writeTelegramSubmittedPrompt(prompt)
            }
            startGeneration(attempt: attempt)
        }

        guard startPanelInput() else {
            statusBar.stop()
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
            }

            switch await submittedLineAction(line, origin: origin) {
            case .continueChat:
                if shouldSuspendPanel {
                    _ = startPanelInput()
                }
                return true
            case .exitChat:
                generationTask?.cancel()
                return false
            case let .runPrompt(prompt):
                if shouldSuspendPanel {
                    _ = startPanelInput()
                }
                let attempt = promptAttempt(prompt: prompt, origin: origin)
                if origin == .local {
                    writeSubmittedPrompt(prompt)
                } else {
                    writeTelegramSubmittedPrompt(prompt)
                }
                startGeneration(attempt: attempt)
                return true
            case let .runHiddenPrompt(prompt, purpose):
                if shouldSuspendPanel {
                    _ = startPanelInput()
                }
                startGeneration(
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
                    _ = startPanelInput()
                }
                interactiveReader.setPanelText(prompt)
                return true
            }
        }

        eventLoop: while true {
            if !isGenerating, !queuedPrompts.isEmpty {
                let nextPrompt = queuedPrompts.removeFirst()
                interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                if nextPrompt.mode == .directPrompt {
                    startDirectPrompt(nextPrompt.text, origin: nextPrompt.origin)
                    continue
                }
                guard await handleSubmittedPanelLine(
                    nextPrompt.text,
                    origin: nextPrompt.origin
                ) else {
                    break eventLoop
                }
                continue
            }

            guard let event = await eventQueue.next() else {
                break eventLoop
            }
            switch event {
            case let .input(inputEvent):
                switch inputEvent {
                case let .submitted(line):
                    if activeVoiceRecordingSession != nil {
                        voiceTranscriptionTask = stopVoiceRecordingAndTranscribe(
                            eventQueue: eventQueue
                        )
                        continue
                    }

                    if isGenerating {
                        switch Self.submittedLineRole(for: line) {
                        case .empty, .prompt:
                            queuedPrompts.append(TerminalQueuedPrompt(text: line, origin: .local))
                            interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                        case .slashCommand:
                            writeFailureMessage(generatingSlashCommandMessage(for: line))
                        }
                        continue
                    }

                    guard await handleSubmittedPanelLine(line) else {
                        break eventLoop
                    }
                case .cancelRequested:
                    if activeVoiceRecordingSession != nil {
                        cancelVoiceRecording()
                    } else if voiceTranscriptionTask != nil {
                        voiceTranscriptionTask?.cancel()
                        voiceTranscriptionTask = nil
                        clearVoicePanelMode()
                        writeSystemMessage("Voice transcription cancelled.\n")
                    } else {
                        generationTask?.cancel()
                    }
                case .toggleToolDetailsRequested:
                    self.toggleToolDetailsOutput()
                    interactiveReader.refreshPanel()
                case .endOfInput:
                    generationTask?.cancel()
                    break eventLoop
                }
            case let .generationCompleted(result):
                generationTask = nil
                isGenerating = false
                statusBar.setProcessing(false)
                interactiveReader.setPanelProcessing(false)
                await finishPromptResult(result)
                refreshStatusBarGitStatusSummaryAfterPromptIfNeeded()
            case let .telegramMessage(message):
                await handleTelegramMessage(
                    message,
                    isGenerating: isGenerating,
                    queuedPrompts: &queuedPrompts,
                    eventQueue: eventQueue
                )
                interactiveReader.setQueuedPromptCount(queuedPrompts.count)
            case let .voicePromptProgress(progress):
                if progress.origin == .local {
                    interactiveReader.setPanelOverlay(
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
                    clearVoicePanelMode()
                    interactiveReader.setPanelProcessing(isGenerating)
                }
                switch result.outcome {
                case let .success(prompt):
                    if isGenerating {
                        queuedPrompts.append(
                            TerminalQueuedPrompt(
                                text: prompt,
                                origin: result.origin,
                                mode: .directPrompt
                            )
                        )
                        interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                        await sendTelegramSystemMessageIfLinked(
                            "Transcription ready. Queued for the current ZenCODE session.",
                            origin: result.origin
                        )
                    } else {
                        await sendTelegramSystemMessageIfLinked(
                            "Transcription ready. ZenCODE is working.",
                            origin: result.origin
                        )
                        startDirectPrompt(prompt, origin: result.origin)
                    }
                case let .failure(message):
                    writeFailureMessage("ZenCODE: \(message)\n")
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
