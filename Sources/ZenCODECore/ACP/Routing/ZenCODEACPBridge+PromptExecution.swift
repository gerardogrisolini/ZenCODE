//
//  ZenCODEACPBridge+PromptExecution.swift
//  ZenCODE
//
//  The execute and settle phases of an ACP session/prompt turn: the turn's
//  task on the model, its update pipeline, and its task-graph presentation.
//

import Foundation
import ToolCore

/// The presentation of a running prompt turn: its update pipeline and the
/// observer of its task graph.
private struct ACPPromptTurnPresentation {
    let pipeline: ACPPromptUpdatePipeline
    let taskPresentation: ACPTaskPresentation
    let graphObserver: Task<Void, Never>
}

extension ZenCODEACPBridge {
    /// Runs the turn's task on the model, with the turn's update pipeline
    /// and task-graph presentation around it, and settles the turn once the
    /// task ends.
    func executePromptTurn(
        _ turn: ACPPromptTurn,
        prompt modelPromptText: String,
        purpose commandPurpose: ACPCommandPromptPurpose,
        attachments: [AgentRuntimeAttachment],
        session: SessionState
    ) async throws -> ACPPromptTurnOutcome {
        let controller = session.controller
        let chatPurpose = Self.chatTurnPurpose(for: commandPurpose, session: session)
        let promptConfiguration = session.configuration.addingAllowedToolNames(
            controller.additionalToolNames(for: chatPurpose)
        )
        let updatePipeline = makePromptUpdatePipeline(turn, modelID: promptConfiguration.modelID)
        // ACP locations must be absolute. Relative tool arguments are resolved
        // by the tools against the session workspace, not against the agent
        // process directory chosen by the launching client.
        let workspaceURL = URL(fileURLWithPath: session.cwd)

        // The session may have been closed, replaced, or shut down while the
        // prompt was being prepared; never start generation for a dead session.
        guard await reservedPromptSession(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) != nil else {
            throw CancellationError()
        }

        let presentation = await startPromptTurnPresentation(turn, session: session, pipeline: updatePipeline)
        let clientFiles = clientTextFileSystem(sessionID: turn.sessionID, epoch: turn.epoch)
        let presenter = ACPPromptPresenter(
            sessionID: turn.sessionID,
            workspaceURL: workspaceURL,
            writer: writer,
            updatePipeline: updatePipeline,
            ensureTasklessObserver: { [weak self] in
                await self?.ensureTasklessObserver(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID)
            },
            claimDelegatedToolNotification: { [weak self] notificationID in
                await self?.claimDelegatedToolNotification(
                    notificationID, sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID
                ) ?? false
            }
        )
        let activePromptTask = Task(name: "ZenCODEACPBridge.prompt") {
            try await ClientTextFileSystem.$current.withValue(clientFiles) {
                await applySelectedAgentSkills(
                    sessionID: promptConfiguration.sessionID,
                    selectedAgent: session.selectedAgent
                )
                try Task.checkCancellation()
                guard let currentSession = await reservedPromptSession(
                    sessionID: turn.sessionID,
                    epoch: turn.epoch,
                    promptID: turn.promptID
                ) else {
                    throw CancellationError()
                }
                let commands = availableCommandsUpdate(for: currentSession)
                if currentSession.presentedCommands != commands {
                    sessions[turn.sessionID]?.presentedCommands = commands
                    await Self.sendPromptUpdate(commands, through: updatePipeline)
                }
                if !currentSession.hasPresentedInitialConfiguration {
                    // Claim before suspending. This flag belongs to this live ACP
                    // incarnation, not to the backend conversation or its snapshot.
                    sessions[turn.sessionID]?.hasPresentedInitialConfiguration = true
                    await Self.sendPromptUpdate(
                        Self.textChunkJSONUpdate(
                            kind: "agent_message_chunk",
                            text: initialConfigurationSummary(for: currentSession)
                        ),
                        through: updatePipeline
                    )
                    // In app mode, do not leave the summary buffered until the
                    // first model event: it must already be visible before generation.
                    await Self.flushPromptUpdates(through: updatePipeline)
                }
                try Task.checkCancellation()
                guard await reservedPromptSession(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) != nil else {
                    throw CancellationError()
                }
                let result = try await controller.runTurn(
                    ChatTurnRequest(
                        prompt: modelPromptText,
                        attachments: attachments,
                        purpose: chatPurpose,
                        sessionConfiguration: promptConfiguration,
                        presenter: presenter
                    )
                )
                return PromptCompletion(
                    text: result.response.text,
                    finalAssistantBlock: result.finalAssistantBlock,
                    stopReason: Self.acpStopReason(result.response.stopReason),
                    modelID: result.response.modelID,
                    fileChangeSummary: result.fileChangeSummary
                )
            }
        }
        try await registerPromptTurnTask(activePromptTask, turn, session: session, presentation: presentation)

        let outcome: ACPPromptTurnOutcome
        // The files the turn changed, from its result or from the failure that
        // ended it (an error or a cancellation carries them too).
        var fileChangeSummary: TurnFileChangeSummary?
        do {
            let completion = try await activePromptTask.value
            fileChangeSummary = completion.fileChangeSummary
            if case .planning = commandPurpose {
                await Self.sendPromptUpdate(
                    Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: completion.text),
                    through: updatePipeline
                )
            }
            outcome = .stopped(stopReason: completion.stopReason)
        } catch {
            // The controller already cleaned up a turn it ran. A turn that
            // stopped before reaching it can only have been cancelled; keep
            // the Planner discussion bound to this live incarnation.
            if !(error is ChatTurnFailure),
               case let .planning(collectionID) = commandPurpose {
                await clearACPPlanBrainstorming(sessionID: turn.sessionID, epoch: turn.epoch, expectedCollectionID: collectionID)
            }
            fileChangeSummary = (error as? ChatTurnFailure)?.fileChangeSummary
            let underlying = (error as? ChatTurnFailure)?.underlying ?? error
            outcome = underlying is CancellationError
                ? .stopped(stopReason: "cancelled")
                : .failed(Self.acpPromptError(for: underlying))
        }
        // Settled once the outcome is known, after the planning text or the
        // brainstorming cleanup it may owe: the order the turn always had.
        await settlePromptTurn(
            turn,
            presentation,
            fileChangeSummary: fileChangeSummary,
            preservingAllowedToolNames: session.allowedToolNames
        )
        return outcome
    }

    /// The update pipeline of one turn: the single serialized exit for
    /// app-mode buffering and ChatGPT-only thinking presentation. Non-app
    /// mode still writes every fragment directly. Overlapping `@Sendable`
    /// callbacks must not interleave buffer drains with writer calls, or a
    /// later notification could overtake content an earlier callback had
    /// already claimed; the pipeline chains every unit so the wire order
    /// equals the enqueue order.
    private func makePromptUpdatePipeline(
        _ turn: ACPPromptTurn,
        modelID: String?
    ) -> ACPPromptUpdatePipeline {
        let normalizesChatGPTThoughts = AgentSettingsStore.defaultSelection(
            explicitModelID: modelID
        )?.remoteProvider?.isChatGPTSubscriptionProvider == true
        return ACPPromptUpdatePipeline(
            sessionID: turn.sessionID,
            writer: writer,
            buffer: ACPPromptUpdateBuffer(),
            buffersUpdates: configuration.appMode,
            normalizesChatGPTThoughts: normalizesChatGPTThoughts,
            isValid: { await self.isCurrentPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) },
            canDeliver: { await self.canDeliverPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) }
        )
    }

    /// Writes `update` through the turn's `pipeline`. Awaiting the unit's
    /// own task preserves the producer's backpressure (the turn does not
    /// advance until the update has actually been written) while the chain
    /// fixes the wire order.
    private static func sendPromptUpdate(_ update: JSONValue, through pipeline: ACPPromptUpdatePipeline) async {
        await pipeline.enqueue(.init(kind: .consume(update))).value
    }

    /// Writes what the turn's `pipeline` buffered.
    private static func flushPromptUpdates(through pipeline: ACPPromptUpdatePipeline) async {
        await pipeline.enqueue(.init(kind: .flush)).value
    }

    /// Gives the live incarnation the turn's update `pipeline` and starts
    /// presenting through it the taskless agents and the task graph.
    private func startPromptTurnPresentation(
        _ turn: ACPPromptTurn,
        session: SessionState,
        pipeline: ACPPromptUpdatePipeline
    ) async -> ACPPromptTurnPresentation {
        updateLiveSession(id: turn.sessionID, epoch: turn.epoch) { live in
            live.promptUpdatePipeline = pipeline
            live.delegatedToolNotifications.removeAll()
        }
        // Persistent taskless agents may run during a text-only follow-up.
        await ensureTasklessObserver(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID)
        let taskPresentation = session.taskPresentation
        let graphEvents = await sessionRunner.taskOrchestrator.events(sessionID: turn.sessionID)
        let graphObserver = Task {
            await publishTaskPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID,
                                          presentation: taskPresentation, pipeline: pipeline)
            for await _ in graphEvents {
                guard !Task.isCancelled else { return }
                await publishTaskPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID,
                                              presentation: taskPresentation, pipeline: pipeline)
            }
        }
        return ACPPromptTurnPresentation(
            pipeline: pipeline,
            taskPresentation: taskPresentation,
            graphObserver: graphObserver
        )
    }

    /// Ends the turn's presentation: the task-graph observer stops, the last
    /// task graph is published through the turn's pipeline, then the Summary of
    /// the files the turn changed (if any), and the pipeline flushes and
    /// drains.
    ///
    /// The Summary is the last text section of the turn: it follows the
    /// final plan and the text the turn owed (the planning answer), and the
    /// reply of the prompt follows it. It is presented here, once the turn's
    /// task has ended, and not when the controller reports it to the presenter,
    /// which happens before the final plan. It goes through the same fence as
    /// the plan, so a turn that lost its incarnation to `session/cancel`, a
    /// close, or a shutdown writes neither.
    ///
    /// The turn gives its pipeline back only once all of that is written. Until
    /// then the session's own observer stays silent (see
    /// `ACPTaskGraphObserver.swift`): the plan is published by the turn, so the
    /// two never write one side by side, and a plan cannot overtake content the
    /// turn still has buffered.
    private func finishPromptTurnPresentation(
        _ turn: ACPPromptTurn,
        _ presentation: ACPPromptTurnPresentation,
        fileChangeSummary: TurnFileChangeSummary? = nil
    ) async {
        presentation.graphObserver.cancel()
        await presentation.graphObserver.value
        await publishTaskPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID,
                                      presentation: presentation.taskPresentation, pipeline: presentation.pipeline)
        await publishFileChangeSummary(fileChangeSummary, for: turn, pipeline: presentation.pipeline)
        await Self.flushPromptUpdates(through: presentation.pipeline)
        await presentation.pipeline.drain()
        if liveSession(id: turn.sessionID, epoch: turn.epoch)?.promptUpdatePipeline === presentation.pipeline {
            let tasklessObserver = sessions[turn.sessionID]?.tasklessObserver
            sessions[turn.sessionID]?.tasklessObserver = nil
            sessions[turn.sessionID]?.promptUpdatePipeline = nil
            tasklessObserver?.cancel()
            await tasklessObserver?.value
        }
    }

    /// Registers the turn's task under the reservation: the bridge's own
    /// entry first, so a `session/cancel` that lands from now on finds the
    /// task and cancels it, then the host's reservation is checked. A cancel
    /// that landed between the reservation and this point already dropped
    /// the reservation, so the check fails and the task is cancelled here
    /// (otherwise the cancel would be silently lost because it had no task
    /// to cancel yet), the turn's presentation ends, and the turn throws.
    private func registerPromptTurnTask(
        _ activePromptTask: Task<PromptCompletion, Error>,
        _ turn: ACPPromptTurn,
        session: SessionState,
        presentation: ACPPromptTurnPresentation
    ) async throws {
        var didRegisterPromptTask = false
        updateLiveSession(id: turn.sessionID, epoch: turn.epoch) { session in
            session.activePromptTask = activePromptTask
            session.activePromptTaskID = turn.promptID
            didRegisterPromptTask = true
        }
        guard didRegisterPromptTask, await host.holdsPrompt(session.promptReservation(turn.promptID)) else {
            activePromptTask.cancel()
            updateLiveSession(id: turn.sessionID, epoch: turn.epoch) { session in
                if session.activePromptTaskID == turn.promptID {
                    session.activePromptTask = nil
                    session.activePromptTaskID = nil
                }
            }
            await finishPromptTurnPresentation(turn, presentation)
            throw CancellationError()
        }
    }

    /// Settles the turn: its task presentation and Summary, its buffered
    /// updates, and the session snapshot.
    private func settlePromptTurn(
        _ turn: ACPPromptTurn,
        _ presentation: ACPPromptTurnPresentation,
        fileChangeSummary: TurnFileChangeSummary?,
        preservingAllowedToolNames allowedToolNames: Set<String>?
    ) async {
        await finishPromptTurnPresentation(turn, presentation, fileChangeSummary: fileChangeSummary)
        await refreshSessionStateIfAvailable(
            sessionID: turn.sessionID,
            preservingAllowedToolNames: allowedToolNames,
            expectedEpoch: turn.epoch,
            expectedPromptID: turn.promptID
        )
    }
}
