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
import ToolCore

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
            lockResponseLanguageIfNeeded()
        }
        let transcriptTurn = TerminalSessionTranscriptTurn(
            prompt: attempt.prompt,
            attachments: attempt.attachments
        )
        let fileChanges = TurnFileChangeCoordinator(
            baseDirectoryURL: configuration.workingDirectory
        )
        await fileChanges.prepareForTurn()
        await beginTelegramTurnProgressReporting(for: attempt.origin)
        // The turn's Telegram reporting ends in `finishPromptResult`, after
        // deferred overview renders and their mirrors have been drained: the
        // final remote message must not overtake sections the turn produced.
        do {
            var sessionConfiguration = await currentSessionConfiguration()
            if case .plan = attempt.purpose {
                var allowedToolNames = sessionConfiguration.allowedToolNames ?? []
                allowedToolNames.insert("todo.write")
                sessionConfiguration = currentSessionConfiguration(
                    allowedToolNames: allowedToolNames,
                    includesActivePlanProgress: false
                )
            } else if case .agentsMarkdown = attempt.purpose {
                var allowedToolNames = sessionConfiguration.allowedToolNames ?? []
                allowedToolNames.formIntersection(Self.agentsMarkdownAllowedToolNames)
                sessionConfiguration = currentSessionConfiguration(
                    allowedToolNames: allowedToolNames,
                    includesActivePlanProgress: false
                )
            } else if case .normal = attempt.purpose,
                      let activePlan,
                      activePlan.isApproved,
                      !activePlan.isCompleted {
                var allowedToolNames = sessionConfiguration.allowedToolNames ?? []
                allowedToolNames.formUnion([
                    "tasks.list", "tasks.get", "tasks.update", "tasks.retry", "tasks.cancel"
                ])
                sessionConfiguration = currentSessionConfiguration(
                    allowedToolNames: allowedToolNames
                )
            } else if case .workflow = attempt.purpose {
                var allowedToolNames = sessionConfiguration.allowedToolNames ?? []
                allowedToolNames.formUnion([
                    "tasks.create", "tasks.list", "tasks.get",
                    "tasks.update", "tasks.retry", "tasks.cancel"
                ])
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
                toolProviders: [],
                onEvent: { @TerminalChatActor event in
                    switch event {
                    case let .status(message):
                        if self.configuration.verboseLogging {
                            await self.writeChatError("[ZenCODE] \(message)\n")
                        }
                    case let .diagnostic(message):
                        if self.configuration.verboseLogging {
                            await self.writeDiagnostic(message)
                        }
                    case let .thought(message):
                        await transcriptTurn.appendThought(message)
                        await self.writeThought(message)
                        await self.activeTelegramProgressReporter?.reportThought(message)
                    case let .modelLoaded(modelID):
                        await self.printModelIfNeeded(modelID)
                    case let .metrics(metrics):
                        self.didReceiveMetricsForCurrentPrompt = true
                        await self.writeMetricsStatus(metrics)
                    case let .contextWindow(status):
                        await self.writeContextWindowStatus(status)
                    case let .subscriptionUsage(status):
                        await self.writeSubscriptionUsageStatus(status)
                    case let .content(delta):
                        if case .plan = attempt.purpose {
                            break
                        }
                        await transcriptTurn.appendAssistantContent(delta)
                        await self.writeAssistantContent(delta)
                        await self.activeTelegramProgressReporter?.reportAssistantContent(delta)
                    case let .toolCallStarted(toolCall):
                        await transcriptTurn.appendToolCallStarted(toolCall)
                        await self.writeToolCallStarted(toolCall)
                        if let telegramProgressReporter = self.activeTelegramProgressReporter {
                            await telegramProgressReporter.reportToolCall(
                                toolCall,
                                workingDirectory: self.configuration.workingDirectory
                            )
                        }
                        await self.publishSubAgentOverviewIfChanged(
                            relatedToolName: toolCall.name
                        )
                        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
                            self.startSubAgentOverviewRefreshIfNeeded()
                        }
                    case let .toolCallCompleted(toolCall, result):
                        await transcriptTurn.appendToolCallCompleted(toolCall, result: result)
                        await self.writeToolCallCompleted(toolCall, result: result)
                        await self.activeTelegramProgressReporter?.reportToolResult(
                            toolCall,
                            result: result
                        )
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
                                await self.synchronizeTaskGraphFromLegacyTodo(
                                    toolCall: toolCall,
                                    result: result
                                )
                            case .agentsMarkdown, .review, .workflow:
                                break
                            }
                        }
                        if !result.isFailure,
                           DirectTaskToolAdapter.isTaskToolName(toolCall.name),
                           let currentPlan = self.activePlan,
                           let graph = try? await self.sessionRunner.taskGraphSnapshot(
                               sessionID: self.sessionID,
                               graphID: currentPlan.id
                           ) {
                            let wasCompleted = currentPlan.isCompleted
                            let projected = Self.plan(currentPlan, applying: graph)
                            self.activePlan = projected
                            if !wasCompleted && projected.isCompleted {
                                await planPointCollector.recordAutomaticCompletion(projected)
                            }
                        }
                        if Self.isFileMutationTool(toolCall.name) {
                            await self.refreshStatusBarGitStatusSummaryForFileMutation()
                        }
                        if await self.shouldPublishDeferredTaskGraphOverview() {
                            await self.publishTaskGraphOverviewIfChanged(
                                observedSessionID: self.sessionID
                            )
                        }
                        await self.publishSubAgentOverviewIfChanged(
                            relatedToolName: toolCall.name
                        )
                        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
                            await self.stopSubAgentOverviewRefresh()
                        }
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
            let agentsMarkdownOutcome: AgentsMarkdownWriteOutcome?
            if case .agentsMarkdown = attempt.purpose {
                agentsMarkdownOutcome = Self.agentsMarkdownWriteOutcome(
                    workingDirectory: configuration.workingDirectory,
                    fileChangeSummary: fileChangeSummary
                )
            } else {
                agentsMarkdownOutcome = nil
            }
            await stopSubAgentOverviewRefresh()
            await renderCoordinator.waitForOverviewMirrorsToDrain()
            await activeTelegramProgressReporter?.flush()
            if case .plan = attempt.purpose {
                await writeAssistantContent(response.text)
            }
            try await recordStructuredPlanIfNeeded(
                responseText: response.text,
                purpose: attempt.purpose,
                points: await planPointCollector.snapshot()
            )
            return TerminalChatGenerationSuccess(
                response: response,
                origin: attempt.origin,
                fileChangeSummary: fileChangeSummary,
                automaticallyCompletedPlan: await planPointCollector.automaticallyCompletedPlan(),
                agentsMarkdownOutcome: agentsMarkdownOutcome
            )
        } catch {
            activeSessionTranscript.append(contentsOf: await transcriptTurn.messages())
            let fileChangeSummary = await collectFileChangeSummaryIfNeeded(from: fileChanges)
            await stopSubAgentOverviewRefresh()
            await renderCoordinator.waitForOverviewMirrorsToDrain()
            await activeTelegramProgressReporter?.flush()
            throw TerminalChatGenerationRunError(
                underlying: error,
                fileChangeSummary: fileChangeSummary
            )
        }
    }

    /// Records a structured plan (with task points) as the active plan **without**
    /// creating its task graph. The graph is created exclusively at plan approval
    /// (see ``handlePlanCommand``) so that changing the plan before approval always
    /// produces a graph that matches the final approved points.
    @discardableResult
    func recordStructuredPlanIfNeeded(
        responseText: String,
        purpose: TerminalPromptPurpose,
        createdAt: Date = Date(),
        points: [TerminalSessionPlanPoint]
    ) async throws(TerminalPlanGenerationError) -> Bool {
        guard case let .plan(originalGoal) = purpose else {
            return false
        }
        let consolidatedText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consolidatedText.isEmpty else {
            return false
        }
        guard !points.isEmpty else {
            throw TerminalPlanGenerationError.structuredTasksUnavailable
        }

        let planID = Self.planID(from: points)
        activePlan = TerminalSessionPlan(
            id: planID,
            originalGoal: originalGoal,
            consolidatedText: consolidatedText,
            createdAt: createdAt,
            isApproved: false,
            points: points
        )
        return true
    }

    nonisolated static func planID(from points: [TerminalSessionPlanPoint]) -> String {
        guard let firstID = points.first?.id.nilIfBlank else {
            return "plan-\(UUID().uuidString.lowercased())"
        }
        let components = firstID.split(separator: "-", omittingEmptySubsequences: false)
        if components.count > 1,
           components.last.flatMap({ Int($0) }) != nil {
            return components.dropLast().joined(separator: "-")
        }
        return "plan-\(UUID().uuidString.lowercased())"
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
            await finishStreamingOutput()
            await printModelIfNeeded(response.modelID)
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let completionText = responseText.isEmpty ? "Done." : responseText
            if responseText.isEmpty {
                await writeChatOutput("Done.")
            }
            await writeChatOutput("\n")
            if let summary = success.fileChangeSummary {
                await writeFileChangeSummary(summary, includeDiff: false)
            }
            if let plan = success.automaticallyCompletedPlan {
                await writeMarkdownMessage(Self.planStatusTable(for: plan))
            }
            if let outcome = success.agentsMarkdownOutcome {
                await writeAgentsMarkdownOutcomeIfNeeded(outcome)
            }
            // Quiesce the debounced task-graph observer and publish the
            // latest known section once while the reporter is still alive;
            // then retire the turn's Telegram reporting, restart the observer
            // for the next turn, and snapshot once more so mutations that
            // landed during the handoff window are not lost (no event replay).
            await quiesceTaskGraphObserverForTurnBoundary()
            await finalizeTelegramTurnProgressReporting()
            await startTaskGraphObserver()
            await publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            await sendTelegramCompletionIfLinked(completionText, origin: success.origin)
        case let .failure(failure):
            await finishStreamingOutput()
            let remoteFailureText: String
            if failure.isCancellation {
                await writeChatError("\nStopped.\n")
                remoteFailureText = "Stopped."
            } else {
                await writeFailureMessage("ZenCODE: \(failure.message)\n")
                remoteFailureText = "ZenCODE failed: \(failure.message)"
            }
            if let summary = failure.fileChangeSummary {
                await writeFileChangeSummary(summary, includeDiff: false)
            }
            await quiesceTaskGraphObserverForTurnBoundary()
            await finalizeTelegramTurnProgressReporting()
            await startTaskGraphObserver()
            await publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            await sendTelegramSystemMessageIfLinked(
                remoteFailureText,
                origin: failure.origin
            )
        }
    }
}
