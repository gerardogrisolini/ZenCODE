//
//  ChatSessionController+Turn.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Per-turn state shared by the runtime event callbacks of one turn.
@ChatSessionActor
final class ChatTurnContext {
    let token: UUID
    let sessionID: String
    let purpose: ChatTurnPurpose
    let transcript: ChatTranscriptTurn
    let collector: PlanningPointCollector
    let artifactTurn: ChatFileArtifactTurn?
    let presenter: any ChatSessionPresenter
    /// History of the last session snapshot the runtime reported this turn.
    var observedHistory: [AgentRuntimeMessage]?

    init(
        token: UUID,
        sessionID: String,
        purpose: ChatTurnPurpose,
        transcript: ChatTranscriptTurn,
        collector: PlanningPointCollector,
        artifactTurn: ChatFileArtifactTurn?,
        presenter: any ChatSessionPresenter
    ) {
        self.token = token
        self.sessionID = sessionID
        self.purpose = purpose
        self.transcript = transcript
        self.collector = collector
        self.artifactTurn = artifactTurn
        self.presenter = presenter
    }

    func isCurrent(in controller: ChatSessionController) -> Bool {
        controller.isCurrentTurn(token, sessionID: sessionID)
    }
}

extension ChatSessionController {
    /// Runs one chat turn: the model request (and, for `/goal`, its automatic
    /// continuations), the purpose-specific bookkeeping, the transcript, and
    /// the file-change summary. Throws ``ChatTurnFailure`` on failure or
    /// cancellation, carrying the file changes the turn still produced.
    func runTurn(_ request: ChatTurnRequest) async throws -> ChatTurnResult {
        let purpose = request.purpose
        let presenter = request.presenter ?? self.presenter
        let turnSessionID = sessionID
        let token = beginTurnToken()
        defer { endTurnToken(token) }
        let turnArtifactHistory = fileArtifactHistory
        let fileChanges = TurnFileChangeCoordinator(baseDirectoryURL: workingDirectory)
        await fileChanges.prepareForTurn()
        let artifactTurn = await beginFileArtifactTurn(coordinator: fileChanges, presenter: presenter)
        let plannerTurnBaseline: PlannerTurnBaseline?
        let planningCollectionID: UUID?
        if case .plan = purpose {
            let snapshots = await runtime.subAgentSnapshots()
            plannerTurnBaseline = PlannerTurnBaseline(
                state: commandState.planBrainstorming,
                snapshots: snapshots,
                rootSessionID: turnSessionID
            )
            planningCollectionID = commandState.planBrainstorming?.collectionID
        } else {
            plannerTurnBaseline = nil
            planningCollectionID = nil
        }
        let transcriptTurn = ChatTranscriptTurn(
            prompt: request.prompt,
            attachments: request.attachments
        )
        let turn = ChatTurnContext(
            token: token,
            sessionID: turnSessionID,
            purpose: purpose,
            transcript: transcriptTurn,
            collector: PlanningPointCollector(),
            artifactTurn: artifactTurn,
            presenter: presenter
        )
        await presenter.turnWillStart(request)
        do {
            var generationPrompt = request.prompt
            var generationAttachments = request.attachments
            var response: DirectAgentResponse
            while true {
                // Evaluated for every request, so an instruction change while a
                // workflow continues turn by turn applies to the next one.
                let turnInstruction = await request.turnInstructionProvider?()
                response = try await runtime.sendPrompt(
                    configuration: request.sessionConfiguration,
                    prompt: generationPrompt,
                    attachments: generationAttachments,
                    authorizeTool: request.authorizeTool,
                    onToolWillExecute: { toolCall in
                        await fileChanges.captureBaselineIfNeeded(forAgentToolCall: toolCall)
                    },
                    toolProviders: [],
                    turnInstruction: turnInstruction,
                    onEvent: { @ChatSessionActor [self] event in
                        await self.handleTurnEvent(event, turn: turn)
                    }
                )
                await presenter.modelTurnDidReturn()
                if case let .workflow(originalGoal, graphID) = purpose {
                    let graph = try? await runtime.taskGraphSnapshot(
                        sessionID: turnSessionID,
                        graphID: graphID
                    )
                    let disposition = PlanningCommandKernel.workflowTurnDisposition(
                        graph: graph,
                        expectedGraphID: graphID,
                        coordinatorMessage: await transcriptTurn.lastAssistantContent()
                    )
                    if case .continueAutomatically = disposition, let graph {
                        await presenter.turnWillContinueAutomatically()
                        await transcriptTurn.flushAssistantMessage()
                        generationPrompt = PlanningCommandKernel.workflowAutomaticContinuationPrompt(
                            goal: originalGoal,
                            graph: graph
                        )
                        generationAttachments = []
                        continue
                    }
                }
                break
            }
            if case let .plan(originalGoal) = purpose {
                response = try await finalizePlanningTurn(
                    parentResponse: response,
                    originalGoal: originalGoal,
                    baseline: plannerTurnBaseline,
                    collectionID: planningCollectionID,
                    collector: turn.collector,
                    transcriptTurn: transcriptTurn,
                    observedHistory: turn.observedHistory,
                    token: token,
                    turnSessionID: turnSessionID
                )
            }
            let messages = await transcriptTurn.messages(finalResponseText: response.text)
            if retainsTranscript, isCurrentTurn(token, sessionID: turnSessionID) {
                appendTranscript(contentsOf: messages)
            }
            let fileChangeSummary = await collectFileChangeSummaryIfNeeded(
                from: fileChanges, sessionID: turnSessionID,
                history: turnArtifactHistory, turnID: artifactTurn?.id,
                presenter: presenter
            )
            await presenter.turnWillFinish()
            if case let .workflow(_, graphID) = purpose,
               isCurrentTurn(token, sessionID: turnSessionID) {
                await recordWorkflowTurnOutcome(
                    graphID: graphID,
                    coordinatorMessage: await transcriptTurn.lastAssistantContent(),
                    token: token,
                    turnSessionID: turnSessionID,
                    presenter: presenter
                )
            }
            if let fileChangeSummary {
                await presenter.presentFileChangeSummary(fileChangeSummary)
            }
            return ChatTurnResult(
                response: response,
                finalAssistantBlock: await transcriptTurn.lastAssistantContent(),
                fileChangeSummary: fileChangeSummary,
                automaticallyCompletedPlan: await turn.collector.automaticallyCompletedPlan()
            )
        } catch {
            if let planningCollectionID {
                await abandonPlanBrainstorming(expectedCollectionID: planningCollectionID)
            }
            if case let .workflow(_, graphID) = purpose,
               isCurrentTurn(token, sessionID: turnSessionID) {
                await handleFailedWorkflowTurn(
                    graphID: graphID,
                    reason: error is CancellationError
                        ? "the turn was cancelled"
                        : error.localizedDescription,
                    token: token,
                    turnSessionID: turnSessionID,
                    presenter: presenter
                )
            }
            let messages = await transcriptTurn.messages()
            if retainsTranscript, isCurrentTurn(token, sessionID: turnSessionID) {
                appendTranscript(contentsOf: messages)
            }
            let fileChangeSummary = await collectFileChangeSummaryIfNeeded(
                from: fileChanges, sessionID: turnSessionID,
                history: turnArtifactHistory, turnID: artifactTurn?.id,
                presenter: presenter
            )
            await presenter.turnWillFinish()
            if let fileChangeSummary {
                await presenter.presentFileChangeSummary(fileChangeSummary)
            }
            throw ChatTurnFailure(underlying: error, fileChangeSummary: fileChangeSummary)
        }
    }

    private func handleTurnEvent(_ event: DirectAgentEvent, turn: ChatTurnContext) async {
        switch event {
        case let .status(status):
            await turn.presenter.presentStatus(status)
        case let .diagnostic(diagnostic):
            await turn.presenter.presentDiagnostic(diagnostic)
        case let .thought(message):
            await turn.transcript.appendThought(message)
            await turn.presenter.presentThought(message)
        case let .modelLoaded(modelID):
            await turn.presenter.presentModelLoaded(modelID)
        case let .metrics(metrics):
            await turn.presenter.presentMetrics(metrics)
        case let .contextWindow(status):
            await turn.presenter.presentContextWindow(status)
        case let .subscriptionUsage(status):
            await turn.presenter.presentSubscriptionUsage(status)
        case let .content(delta):
            guard !turn.purpose.suppressesCoordinatorContent else { break }
            await turn.transcript.appendAssistantContent(delta)
            await turn.presenter.presentAssistantContent(delta)
        case let .toolCallStarted(toolCall):
            await turn.transcript.appendToolCallStarted(toolCall)
            await turn.presenter.presentToolCallStarted(toolCall)
        case let .toolCallCompleted(toolCall, result):
            await turn.transcript.appendToolCallCompleted(toolCall, result: result)
            await turn.presenter.presentToolCallCompleted(toolCall, result: result)
            await publishLiveFileArtifacts(
                result, callID: toolCall.id, context: turn.artifactTurn
            )
            await recordPlanProgress(toolCall: toolCall, result: result, turn: turn)
            await turn.presenter.presentToolCallSettled(toolCall, result: result)
        case let .sessionSnapshot(snapshot):
            guard turn.isCurrent(in: self) else { break }
            cacheKey = snapshot.cacheKey
            history = snapshot.history
            turn.observedHistory = snapshot.history
        case let .turnEnded(outcome):
            await turn.presenter.presentTurnEnded(outcome)
        }
    }
}
