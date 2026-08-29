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
        await installSubAgentToolEventHandlerIfNeeded()
        let planPointCollector = TerminalPlanPointCollector()
        let turnSessionID = sessionID
        let plannerTurnBaseline: PlannerTurnBaseline?
        let planningCollectionID: UUID?
        if case .plan = attempt.purpose {
            let snapshots = await sessionRunner.subAgentSnapshots()
            plannerTurnBaseline = PlannerTurnBaseline(
                state: planBrainstorming,
                snapshots: snapshots,
                rootSessionID: turnSessionID
            )
            planningCollectionID = planBrainstorming?.collectionID
        } else {
            plannerTurnBaseline = nil
            planningCollectionID = nil
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
                    case .status, .diagnostic:
                        break
                    case let .thought(message):
                        await transcriptTurn.appendThought(message)
                        await self.writeThought(message)
                    case let .modelLoaded(modelID):
                        await self.printModelIfNeeded(modelID)
                    case let .metrics(metrics):
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
                        await self.appendTelegramRootResponseDelta(delta)
                    case let .toolCallStarted(toolCall):
                        await transcriptTurn.appendToolCallStarted(toolCall)
                        await self.writeToolCallStarted(toolCall)
                        // The tool call closes the root response that preceded
                        // it: publish that response, never the call itself.
                        await self.publishTelegramRootResponseAtToolBoundary()
                        await self.publishSubAgentOverviewIfChanged(
                            relatedToolName: toolCall.name
                        )
                        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
                            self.startSubAgentOverviewRefreshIfNeeded()
                        }
                    case let .toolCallCompleted(toolCall, result):
                        await transcriptTurn.appendToolCallCompleted(toolCall, result: result)
                        await self.writeToolCallCompleted(toolCall, result: result)
                        let planPointUpdate = result.isFailure
                            ? nil
                            : Self.planPointUpdates(from: toolCall)
                        switch attempt.purpose {
                        case .plan:
                            let request = DirectTodoTaskRuntime.normalizedToolRequest(
                                for: toolCall
                            )
                            if request.name == "todo.write" {
                                await planPointCollector.recordTodoWrite(planPointUpdate)
                            }
                        case .normal:
                            if planPointUpdate != nil {
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
                            }
                        case .review, .workflow:
                            break
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
                guard let plannerTurnBaseline,
                      let plannerResult = PlanningCommandKernel.plannerResponse(
                    parentResponse: response,
                    snapshots: await sessionRunner.subAgentSnapshots(),
                    baseline: plannerTurnBaseline,
                    rootSessionID: turnSessionID
                ) else {
                    throw TerminalPlanGenerationError.plannerOutputUnavailable
                }
                guard let planningCollectionID,
                      var brainstorming = planBrainstorming,
                      brainstorming.collectionID == planningCollectionID else {
                    throw CancellationError()
                }
                brainstorming.recordPlannerOutput(
                    plannerResult.response.text,
                    agentID: plannerResult.snapshot.id,
                    revision: plannerResult.snapshot.latestOutputRevision
                )
                response = plannerResult.response
                let plannerPoints: [TerminalSessionPlanPoint]
                if PlanningCommandKernel.isPlannerQuestionResponse(response.text) {
                    guard !(await planPointCollector.hasObservedTodoWrites()) else {
                        throw TerminalPlanGenerationError.unexpectedStructuredTasksForQuestions
                    }
                    plannerPoints = []
                } else {
                    guard let finalPoints = await planPointCollector.finalPlanPoints(
                        forFinalText: response.text
                    ) else {
                        throw TerminalPlanGenerationError.structuredTasksUnavailable
                    }
                    plannerPoints = finalPoints
                }
                let historyBeforePlannerCorrection = activeSessionHistory
                let correctedPlanningHistory = PlanningCommandKernel.historyByReplacingCoordinatorOutput(
                    activeSessionHistory,
                    with: response.text
                )
                guard await sessionRunner.replaceSessionHistory(
                    id: turnSessionID,
                    history: correctedPlanningHistory
                ) else {
                    throw TerminalPlanGenerationError.sessionHistoryUnavailable
                }
                guard sessionID == turnSessionID,
                      let currentPlanningState = planBrainstorming,
                      currentPlanningState.collectionID == planningCollectionID else {
                    if let installed = await sessionRunner.snapshotSession(id: turnSessionID),
                       installed.history == correctedPlanningHistory {
                        _ = await sessionRunner.replaceSessionHistory(
                            id: turnSessionID,
                            history: historyBeforePlannerCorrection
                        )
                    }
                    throw CancellationError()
                }
                activeSessionHistory = correctedPlanningHistory
                if PlanningCommandKernel.isPlannerQuestionResponse(response.text) {
                    planBrainstorming = brainstorming
                } else {
                    try await recordStructuredPlanIfNeeded(
                        responseText: response.text,
                        purpose: attempt.purpose,
                        points: plannerPoints
                    )
                    planBrainstorming = nil
                }
                await transcriptTurn.appendAssistantContent(response.text)
            }
            appendActiveSessionTranscript(
                contentsOf: await transcriptTurn.messages(finalResponseText: response.text)
            )
            let fileChangeSummary = await collectFileChangeSummaryIfNeeded(from: fileChanges)
            await stopSubAgentOverviewRefresh()
            await renderCoordinator.waitForOverviewMirrorsToDrain()
            if case .plan = attempt.purpose {
                await writeAssistantContent(response.text)
            } else {
                try await recordStructuredPlanIfNeeded(
                    responseText: response.text,
                    purpose: attempt.purpose,
                    points: await planPointCollector.snapshot()
                )
            }
            if case let .workflow(_, graphID) = attempt.purpose,
               sessionID == turnSessionID {
                await recordWorkflowTurnOutcome(
                    graphID: graphID,
                    coordinatorMessage: await transcriptTurn.lastAssistantContent()
                )
            }
            return TerminalChatGenerationSuccess(
                response: response,
                origin: attempt.origin,
                fileChangeSummary: fileChangeSummary,
                automaticallyCompletedPlan: await planPointCollector.automaticallyCompletedPlan()
            )
        } catch {
            if let planningCollectionID {
                await abandonPlanBrainstorming(
                    expectedCollectionID: planningCollectionID
                )
            }
            if case let .workflow(_, graphID) = attempt.purpose,
               sessionID == turnSessionID {
                await handleFailedWorkflowTurn(
                    graphID: graphID,
                    reason: error is CancellationError
                        ? "the turn was cancelled"
                        : error.localizedDescription
                )
            }
            appendActiveSessionTranscript(contentsOf: await transcriptTurn.messages())
            let fileChangeSummary = await collectFileChangeSummaryIfNeeded(from: fileChanges)
            await stopSubAgentOverviewRefresh()
            await renderCoordinator.waitForOverviewMirrorsToDrain()
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
        PlanningCommandKernel.planID(from: points)
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
            if let plan = success.automaticallyCompletedPlan {
                await writeMarkdownMessage(Self.planStatusTable(for: plan))
            }
            // Quiesce the debounced task-graph observer and publish the
            // latest known section once while the reporter is still alive;
            // then retire the turn's Telegram reporting, restart the observer
            // for the next turn, and snapshot once more so mutations that
            // landed during the handoff window are not lost (no event replay).
            await quiesceTaskGraphObserverForTurnBoundary()
            let mirroredCompletionText = await telegramMirroredFinalResponseText(
                fallback: completionText
            )
            await finalizeTelegramTurnProgressReporting(
                outcome: .agentResponse(
                    "*ZenCODE completed*\n\n\(String(mirroredCompletionText.prefix(3_600)))"
                ),
                fileChangeSummary: success.fileChangeSummary
            )
            await startTaskGraphObserver()
            await publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            if let summary = success.fileChangeSummary {
                await writeFinalFileChangeSummary(summary)
            }
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
            await quiesceTaskGraphObserverForTurnBoundary()
            await finalizeTelegramTurnProgressReporting(
                outcome: .agentResponse(remoteFailureText),
                fileChangeSummary: failure.fileChangeSummary
            )
            await startTaskGraphObserver()
            await publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            if let summary = failure.fileChangeSummary {
                await writeFinalFileChangeSummary(summary)
            }
        }
    }
}
