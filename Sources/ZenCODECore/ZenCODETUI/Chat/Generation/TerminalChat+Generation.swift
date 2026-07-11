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
        let planPointCollector = TerminalPlanPointCollector()
        let preexistingSubAgentIDs: Set<String>
        if case .plan = attempt.purpose {
            preexistingSubAgentIDs = Set(
                await sessionRunner.subAgentSnapshots().map(\.id)
            )
        } else {
            preexistingSubAgentIDs = []
        }
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
        await fileChanges.prepareForTurn()
        let telegramProgressReporter = telegramControlState.isActive
            ? makeTelegramTurnProgressReporter(for: attempt.origin)
            : nil
        if let telegramProgressReporter = telegramProgressReporter {
            await telegramProgressReporter.enqueue(
                telegramTurnStartedMessage(prompt: attempt.prompt)
            )
        }
        do {
            var sessionConfiguration = await currentSessionConfiguration()
            if case .plan = attempt.purpose {
                var allowedToolNames = sessionConfiguration.allowedToolNames ?? []
                allowedToolNames.insert("todo.write")
                sessionConfiguration = currentSessionConfiguration(
                    allowedToolNames: allowedToolNames,
                    includesActivePlanProgress: false
                )
            } else if case .normal = attempt.purpose,
                      let activePlan,
                      activePlan.isApproved,
                      !activePlan.isCompleted {
                var allowedToolNames = sessionConfiguration.allowedToolNames ?? []
                allowedToolNames.insert("todo.write")
                sessionConfiguration = currentSessionConfiguration(
                    allowedToolNames: allowedToolNames
                )
            } else if case .review = attempt.purpose {
                sessionConfiguration = currentSessionConfiguration(
                    allowedToolNames: sessionConfiguration.allowedToolNames ?? [],
                    includesActivePlanProgress: false
                )
            }
            var response = try await sessionRunner.sendPrompt(
                configuration: sessionConfiguration,
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
                        if case .plan = attempt.purpose {
                            break
                        }
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
                        await self.publishSubAgentOverviewIfChanged(
                            relatedToolName: toolCall.name
                        )
                    case let .toolCallCompleted(toolCall, result):
                        await transcriptTurn.appendToolCallCompleted(toolCall, result: result)
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallCompleted(toolCall, result: result)
                        if !result.isFailure,
                           let update = Self.planPointUpdates(from: toolCall) {
                            switch attempt.purpose {
                            case .plan:
                                await planPointCollector.apply(
                                    update.points,
                                    mode: update.mode
                                )
                            case .normal:
                                if self.synchronizeActivePlanStatus(
                                    from: toolCall,
                                    result: result
                                ), let plan = self.activePlan {
                                    await planPointCollector.recordAutomaticCompletion(plan)
                                }
                            case .review:
                                break
                            }
                        }
                        if Self.isFileMutationTool(toolCall.name) {
                            self.refreshStatusBarGitStatusSummaryForFileMutation()
                        }
                        await self.publishSubAgentOverviewIfChanged(
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
            if case .plan = attempt.purpose {
                guard let plannerResponse = Self.plannerAuthoredPlanResponse(
                    parentResponse: response,
                    snapshots: await sessionRunner.subAgentSnapshots(),
                    excludingAgentIDs: preexistingSubAgentIDs
                ) else {
                    throw TerminalPlanGenerationError.plannerOutputUnavailable
                }
                response = plannerResponse
                activeSessionHistory = Self.historyByReplacingPlanCoordinatorOutput(
                    activeSessionHistory,
                    with: response.text
                )
                guard await sessionRunner.replaceSessionHistory(
                    id: sessionID,
                    history: activeSessionHistory
                ) else {
                    throw TerminalPlanGenerationError.sessionHistoryUnavailable
                }
                await transcriptTurn.appendAssistantContent(response.text)
            }
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
            await publishSubAgentOverviewIfChanged()
            await telegramProgressReporter?.flush()
            if case .plan = attempt.purpose {
                finishThoughtOutputIfNeeded()
                writeAssistantContent(response.text)
            }
            recordPlanIfNeeded(
                responseText: response.text,
                purpose: attempt.purpose,
                points: await planPointCollector.snapshot()
            )
            return TerminalChatGenerationSuccess(
                response: response,
                origin: attempt.origin,
                fileChangeSummary: fileChangeSummary,
                automaticallyCompletedPlan: await planPointCollector.automaticallyCompletedPlan()
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
            await publishSubAgentOverviewIfChanged()
            await telegramProgressReporter?.flush()
            throw TerminalChatGenerationRunError(
                underlying: error,
                fileChangeSummary: fileChangeSummary
            )
        }
    }

    @discardableResult
    func recordPlanIfNeeded(
        responseText: String,
        purpose: TerminalPromptPurpose,
        createdAt: Date = Date(),
        points: [TerminalSessionPlanPoint] = []
    ) -> Bool {
        guard case let .plan(originalGoal) = purpose else {
            return false
        }
        let consolidatedText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consolidatedText.isEmpty else {
            return false
        }
        activePlan = TerminalSessionPlan(
            originalGoal: originalGoal,
            consolidatedText: consolidatedText,
            createdAt: createdAt,
            isApproved: false,
            points: points
        )
        return true
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
            if responseText.isEmpty {
                writeChatOutput("Done.")
            }
            writeChatOutput("\n")
            if let summary = success.fileChangeSummary {
                writeFileChangeSummary(summary, includeDiff: false)
            }
            if let plan = success.automaticallyCompletedPlan {
                writeMarkdownMessage(Self.planStatusTable(for: plan))
            }
            await sendTelegramCompletionIfLinked(completionText, origin: success.origin)
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
