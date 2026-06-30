//
//  TerminalChat+Generation.swift
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
    func generateResponse(
        attempt: TerminalPromptAttempt
    ) async throws -> TerminalChatGenerationSuccess {
        if attempt.locksResponseLanguage {
            lockResponseLanguageIfNeeded(from: attempt.prompt)
        }
        let transcriptTurn = TerminalSessionTranscriptTurn(
            prompt: attempt.prompt,
            attachments: attempt.attachments
        )
        let fileChanges = TurnFileChangeCoordinator(
            baseDirectoryURL: configuration.workingDirectory
        )
        let telegramProgressReporter = telegramControlState.isActive
            ? makeTelegramTurnProgressReporter(for: attempt.origin)
            : nil
        if let telegramProgressReporter = telegramProgressReporter {
            await telegramProgressReporter.enqueue(
                telegramTurnStartedMessage(prompt: attempt.prompt)
            )
        }
        do {
            let response = try await sessionRunner.sendPrompt(
                configuration: await currentSessionConfiguration(),
                prompt: attempt.prompt,
                attachments: attempt.attachments,
                authorizeTool: telegramToolAuthorizationHandler(for: attempt.origin),
                onToolWillExecute: { toolCall in
                    await fileChanges.captureBaselineIfNeeded(
                        forAgentToolCall: toolCall
                    )
                },
                onEvent: { event in
                    switch event {
                    case let .status(message):
                        if self.configuration.verboseLogging {
                            self.writeChatError("[ZenCODE] \(message)\n")
                        }
                    case let .diagnostic(message):
                        if self.configuration.verboseLogging {
                            self.writeDiagnostic(message)
                        }
                    case let .thought(message):
                        await transcriptTurn.appendThought(message)
                        self.writeThought(message)
                    case let .modelLoaded(modelID):
                        self.printModelIfNeeded(modelID)
                    case let .modelLoadedDetails(details):
                        self.printLoadedModelDetails(details)
                    case let .modelRuntime(runtime):
                        _ = self.statusBar.update(modelRuntime: runtime)
                    case let .metrics(metrics):
                        self.didReceiveMetricsForCurrentPrompt = true
                        self.writeMetricsStatus(metrics)
                    case let .contextWindow(status):
                        self.writeContextWindowStatus(status)
                    case let .subscriptionUsage(status):
                        self.writeSubscriptionUsageStatus(status)
                    case let .content(delta):
                        await transcriptTurn.appendAssistantContent(delta)
                        self.finishThoughtOutputIfNeeded()
                        self.writeAssistantContent(delta)
                    case let .toolCallStarted(toolCall):
                        await transcriptTurn.appendToolCallStarted(toolCall)
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallStarted(toolCall)
                        if let telegramProgressReporter = telegramProgressReporter {
                            await telegramProgressReporter.enqueue(
                                self.telegramToolStartedMessage(toolCall)
                            )
                        }
                        await self.publishSubAgentOverviewIfVisible(
                            relatedToolName: toolCall.name
                        )
                    case let .toolCallCompleted(toolCall, result):
                        await transcriptTurn.appendToolCallCompleted(toolCall, result: result)
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallCompleted(toolCall, result: result)
                        if Self.isFileMutationTool(toolCall.name) {
                            self.refreshStatusBarGitStatusSummaryForFileMutation()
                        }
                        await self.publishSubAgentOverviewIfVisible(
                            relatedToolName: toolCall.name
                        )
                    case let .sessionSnapshot(snapshot):
                        self.activeSessionCacheKey = snapshot.cacheKey
                        self.activeSessionHistory = snapshot.history
                    case .turnEnded:
                        break
                    }
                }
            )
            activeSessionTranscript.append(
                contentsOf: await transcriptTurn.messages(finalResponseText: response.text)
            )
            let fileChangeSummary = await collectFileChangeSummaryIfNeeded(from: fileChanges)
            if let telegramProgressReporter = telegramProgressReporter,
               let summary = fileChangeSummary {
                await telegramProgressReporter.enqueue(
                    telegramFileChangeSummaryMessage(summary)
                )
            }
            await publishSubAgentOverviewIfVisible()
            await telegramProgressReporter?.flush()
            return TerminalChatGenerationSuccess(
                response: response,
                origin: attempt.origin,
                fileChangeSummary: fileChangeSummary
            )
        } catch {
            activeSessionTranscript.append(contentsOf: await transcriptTurn.messages())
            let fileChangeSummary = await collectFileChangeSummaryIfNeeded(from: fileChanges)
            if let telegramProgressReporter = telegramProgressReporter,
               let summary = fileChangeSummary {
                await telegramProgressReporter.enqueue(
                    telegramFileChangeSummaryMessage(summary)
                )
            }
            await publishSubAgentOverviewIfVisible()
            await telegramProgressReporter?.flush()
            throw TerminalChatGenerationRunError(
                underlying: error,
                fileChangeSummary: fileChangeSummary
            )
        }
    }

    func finishPromptResult(_ result: TerminalChatGenerationResult) async {
        switch result {
        case let .success(success):
            let response = success.response
            finishThoughtOutputIfNeeded()
            finishAssistantContentFormatting()
            printModelIfNeeded(response.modelID)
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let completionText = responseText.isEmpty ? "Done." : responseText
            lastAssistantResponseText = completionText
            if responseText.isEmpty {
                writeChatOutput("Done.")
            }
            writeChatOutput("\n")
            if let summary = success.fileChangeSummary {
                writeFileChangeSummary(summary, includeDiff: false)
            }
            if success.origin.isTelegramVoice {
                await sendTelegramVoiceCompletionIfLinked(completionText, origin: success.origin)
            } else {
                await sendTelegramCompletionIfLinked(completionText, origin: success.origin)
            }
        case let .failure(failure):
            finishThoughtOutputIfNeeded()
            finishAssistantContentFormatting()
            if failure.isCancellation {
                writeChatError("\nStopped.\n")
                await sendTelegramSystemMessageIfLinked("Stopped.", origin: failure.origin)
            } else {
                writeFailureMessage("ZenCODE: \(failure.message)\n")
                await sendTelegramSystemMessageIfLinked(
                    "ZenCODE failed: \(failure.message)",
                    origin: failure.origin
                )
            }
            if let summary = failure.fileChangeSummary {
                writeFileChangeSummary(summary, includeDiff: false)
            }
        }
    }
}
