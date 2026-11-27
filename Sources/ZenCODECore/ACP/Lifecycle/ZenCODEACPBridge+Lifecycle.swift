//
//  ZenCODEACPBridge+Lifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension ZenCODEACPBridge {
    public func newSession(id: JSONValue?, params: [String: Any]) async throws {
        try ensureConfigured()
        // Claim the operation synchronously, before the first `await`: from now
        // on a concurrent `shutdown()` invalidates this token and every
        // re-check below aborts instead of creating a session or a backend.
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }
        let rawCwd = Self.workingDirectory(from: params)
            ?? configuration.workingDirectory.path
        let cwd = AgentConfiguration.resolvedWorkingDirectory(
            rawValue: rawCwd,
            applyLaunchDirectoryFallback: false
        ).path
        try ensureLifecycleOperationLive(operation)
        let workingDirectoryURL = URL(fileURLWithPath: cwd)
        let selectedAgent = try resolvedACPAgentProfile(
            from: params,
            workingDirectory: workingDirectoryURL
        )
        // The session's agent is resolved first: without a client model, its
        // default binding is the session's model.
        let requestedModelID = Self.modelID(from: params)
        let modelID = requestedModelID
            ?? defaultSessionModelID(for: selectedAgent)
        let sessionID = "swift-agent-\(UUID().uuidString.lowercased())"
        // The session's own tool grant: the request's, else the agent's. The
        // tools of the MCP servers the client provides, or of the features that
        // replace them, are added to it once they are installed.
        let resolvedRequestedAllowedToolNames = await requestedSessionAllowedToolNames(
            from: params,
            selectedAgent: selectedAgent,
            workingDirectory: workingDirectoryURL
        )
        try ensureLifecycleOperationLive(operation)
        let (sessionEpoch, offersResumableTaskGraphs) = try await withNewIncarnation(
            sessionID: sessionID,
            cwd: cwd,
            params: params,
            operation: operation
        ) { incarnation, acpMCPServers in
            let cacheKey = (params["sessionKey"] as? String)
                ?? (params["cacheKey"] as? String)
            let baseAllowedToolNames = Self.sessionBaseAllowedToolNames(
                resolvedRequestedAllowedToolNames,
                adding: acpMCPServers
            )
            let allowedToolNames = Self.narrowedSessionAllowedToolNames(
                baseAllowedToolNames,
                selectedAgent: selectedAgent
            )
            try ensureLifecycleOperationLive(operation)
            let promptSections = resolvedPromptSections(
                providedSystemPrompt: nil,
                cwd: cwd,
                allowedToolNames: allowedToolNames,
                selectedAgent: selectedAgent
            )
            let requestedThinkingSelection = Self.thinkingSelection(from: params["thinkingSelection"])
            let thinkingSelection = modelCatalog.resolvedThinkingSelection(
                requested: requestedThinkingSelection,
                explicitModelID: requestedModelID ?? configuration.modelID,
                agentModelID: selectedAgent?.modelID,
                agentThinkingSelection: selectedAgent?.thinkingSelection,
                selectedModelID: modelID
            )
            let preserveThinking = (params["preserveThinking"] as? Bool) ?? false
            let runnerConfiguration = AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: modelID,
                agentID: selectedAgent?.id,
                agentName: selectedAgent?.name,
                agentRole: selectedAgent?.role,
                workingDirectory: cwd,
                systemPrompt: promptSections.systemPrompt,
                dynamicContext: promptSections.dynamicContext,
                cacheKey: cacheKey,
                history: Self.runtimeHistory(from: params["history"]),
                allowedToolNames: allowedToolNames,
                maxToolRounds: self.configuration.maxToolRounds,
                maxOutputTokens: self.configuration.maxOutputTokens,
                appMode: self.configuration.appMode,
                thinkingSelection: thinkingSelection,
                preserveThinking: preserveThinking
            )
            // Past the last fence the session entry, the runner session and
            // the JSON-RPC reply are published.
            try publishNewIncarnation(
                incarnation,
                sessionID: sessionID,
                configuration: runnerConfiguration,
                selectedAgent: selectedAgent,
                baseAllowedToolNames: baseAllowedToolNames,
                operation: operation
            )
            // A runner session that cannot be created leaves no session
            // entry behind: the cleanup drops our own incarnation's entry.
            try await sessionRunner.createSession(configuration: runnerConfiguration)
            // Whether earlier sessions left task graphs to offer: only then
            // is the startup offer registered below.
            let offersResumableTaskGraphs = await hasOfferableResumableTaskGraphs(
                sessionID: sessionID,
                workingDirectory: workingDirectoryURL
            )
            // `createSession` and the scan suspend: if a shutdown or a
            // `session/close` landed during them, close the runner session we
            // just created instead of announcing it.
            try await ensureLifecycleOperationLiveAfterSessionWrite(
                operation,
                sessionID: sessionID
            )
            return (incarnation.epoch, offersResumableTaskGraphs)
        }

        // The startup offer of the task graphs earlier sessions left
        // incomplete, when there are any, is registered before the reply, so
        // a prompt sent right after it waits for the offer, and asks only
        // once the session is announced (see
        // `ZenCODEACPBridge+ResumeTaskGraph.swift`).
        let resumableTaskGraphOfferGate = offersResumableTaskGraphs
            ? registerResumableTaskGraphOffer(sessionID: sessionID, epoch: sessionEpoch)
            : nil
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: URL(fileURLWithPath: cwd).lastPathComponent
        )
        await publishAvailableCommands(sessionID: sessionID, epoch: sessionEpoch)
        // The incarnation's observer publishes the plan of every graph change
        // the prompts do not own (see `ACPTaskGraphObserver.swift`). It starts
        // after the session's reply, as its info and commands do, so the client
        // knows the session before its first `plan`.
        await startTaskGraphObserverIfNeeded(sessionID: sessionID, epoch: sessionEpoch)
        resumableTaskGraphOfferGate?.finish()
    }

    /// Opens, for the lifecycle `operation`, a new incarnation of the ACP
    /// session `sessionID` in `cwd`, installs the MCP servers `params`
    /// provide, and runs `body` with the incarnation and what those servers
    /// contribute to the session's grant: the shared part of `session/new` and
    /// of the restore of a session that is not live. A server that a loaded
    /// feature of the same name replaces is not installed, whatever the
    /// session's tool grant selects; the feature's tool names stand in its
    /// place in `acpMCPServers` (see `installACPProvidedMCPServers`).
    ///
    /// The incarnation is opened in the host before the MCP servers are
    /// installed: the ownership stamped on those registrations identifies
    /// exactly the incarnation the handler is about to publish, so a failed
    /// or fenced creation can release them again. Every `throw` after the
    /// opening, `body`'s included, means the incarnation never became (or did
    /// not stay) live: its session entry, if it is still ours, is dropped
    /// (a racing handler's newer incarnation is never touched), its host slot
    /// is closed (already, when the entry was dropped), and its MCP
    /// registrations are released before the error propagates. A successful
    /// exit keeps them bound to the live session.
    private func withNewIncarnation<Value>(
        sessionID: String,
        cwd: String,
        params: [String: Any],
        operation: UInt64,
        _ body: (_ incarnation: ChatSessionIncarnation, _ acpMCPServers: ACPProvidedMCPServers) async throws -> Value
    ) async throws -> Value {
        let incarnation = try await openACPSession(sessionID: sessionID, cwd: cwd)
        do {
            try ensureLifecycleOperationLive(operation)
            let acpMCPServers = await installACPProvidedMCPServers(
                from: params,
                ownership: DirectMCPToolRuntime.MCPSessionOwnership(
                    sessionID: sessionID,
                    epoch: incarnation.epoch
                ),
                operation: operation
            )
            try ensureLifecycleOperationLive(operation)
            return try await body(incarnation, acpMCPServers)
        } catch {
            await discardSessionIfCurrent(id: sessionID, epoch: incarnation.epoch)
            await closeACPSlot(of: incarnation)
            await sessionRunner.releaseSessionMCPOwnership(
                sessionID: sessionID,
                epoch: incarnation.epoch
            )
            throw error
        }
    }

    /// Publishes the entry of the new `incarnation` of `sessionID` and binds
    /// the lifecycle `operation` to it, after the last fence before any
    /// observable effect: a shutdown that lands right before must abort
    /// rather than leave a live session and a backend behind a closed
    /// transport. From here the session exists, so a `session/close` for it
    /// invalidates the handler before it answers.
    private func publishNewIncarnation(
        _ incarnation: ChatSessionIncarnation,
        sessionID: String,
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile?,
        baseAllowedToolNames: Set<String>? = nil,
        savedSessionLink: ACPSavedSessionLink? = nil,
        promptDisplayTexts: [String: String] = [:],
        operation: UInt64
    ) throws {
        try ensureLifecycleOperationLive(operation)
        var sessionEntry = sessionState(
            configuration: configuration,
            selectedAgent: selectedAgent,
            incarnation: incarnation,
            baseAllowedToolNames: baseAllowedToolNames
        )
        sessionEntry.savedSessionLink = savedSessionLink
        sessionEntry.promptDisplayTexts = promptDisplayTexts
        sessions[sessionID] = sessionEntry
        bindLifecycleOperation(operation, sessionID: sessionID, epoch: incarnation.epoch)
    }

    /// The session's own tool grant, before the selected agent narrows it: the
    /// resolved request, with the tools of the MCP servers the session provided
    /// (or, for a server a loaded feature of the same name replaced, the tools
    /// of that feature) and the prompt-skill tools. `nil` (no restriction)
    /// stays `nil` unless a server or a replacing feature adds names to it.
    static func sessionBaseAllowedToolNames(
        _ resolvedRequestedAllowedToolNames: Set<String>?,
        adding acpMCPServers: ACPProvidedMCPServers
    ) -> Set<String>? {
        var allowedToolNames = Self.allowedToolNames(
            resolvedRequestedAllowedToolNames,
            adding: acpMCPServers.descriptors,
            replacingFeatureToolNames: acpMCPServers.replacingFeatureToolNames
        )
        if var effectiveAllowedToolNames = allowedToolNames {
            effectiveAllowedToolNames.formUnion(PromptSkillToolProvider.toolNames)
            allowedToolNames = effectiveAllowedToolNames
        }
        return allowedToolNames
    }

    /// The session's own tool grant narrowed by `selectedAgent`'s policy: the
    /// recomposition an agent mention applies to a live session.
    static func narrowedSessionAllowedToolNames(
        _ baseAllowedToolNames: Set<String>?,
        selectedAgent: AgentProfile?
    ) -> Set<String>? {
        guard let selectedAgent, let effectiveAllowedToolNames = baseAllowedToolNames else {
            return baseAllowedToolNames
        }
        return selectedAgent.resolvedAllowedToolNames(effectiveAllowedToolNames)
    }

    public func resolvedAllowedToolNames(
        _ requestedAllowedToolNames: Set<String>?,
        workingDirectory: URL
    ) async -> Set<String>? {
        _ = workingDirectory
        return ExternalToolAvailability.resolvedAllowedToolNames(requestedAllowedToolNames)
    }

    /// The tools a new session asks for on its own, before the tools of the
    /// MCP servers it provides, or of the features that replace them, are
    /// added: the request's, else the selected agent's. `nil` is a request
    /// with no tool grant of its own.
    private func requestedSessionAllowedToolNames(
        from params: [String: Any],
        selectedAgent: AgentProfile?,
        workingDirectory: URL
    ) async -> Set<String>? {
        await resolvedAllowedToolNames(
            Self.allowedToolNames(from: params) ?? selectedAgent?.allowedToolNames(),
            workingDirectory: workingDirectory
        )
    }

    public func loadSession(id: JSONValue?, params: [String: Any]) async throws {
        try await restoreSession(id: id, params: params, replayHistory: true)
    }

    public func resumeSession(id: JSONValue?, params: [String: Any]) async throws {
        try await restoreSession(id: id, params: params, replayHistory: false)
    }

    public func restoreSession(
        id: JSONValue?,
        params: [String: Any],
        replayHistory: Bool
    ) async throws {
        try ensureConfigured()
        // Same claim-before-first-await rule as `newSession`: `session/load`
        // and `session/resume` also create sessions and backends.
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }

        // A session_id is optional: stateless clients can resume by resending
        // their transcript. When omitted we mint an internal session id.
        let sessionID = Self.sessionID(from: params)
            ?? "swift-agent-\(UUID().uuidString.lowercased())"
        if let session = sessions[sessionID] {
            // Bind before the first suspension: a concurrent close must fence
            // both the Planner teardown and the subsequent replay/reply.
            bindLifecycleOperation(operation, sessionID: sessionID, epoch: session.epoch)
            // ACP load/resume is a restore boundary even when the client reuses
            // an already-live id. Never infer an unfinished Planner exchange
            // from replayed chat history.
            await clearACPPlanBrainstorming(sessionID: sessionID, epoch: session.epoch)
            // The approval handshake is the controller's transient state: it
            // is cleared under the controller's lock, inside the fenced step.
            _ = updateLiveSession(id: sessionID, epoch: session.epoch) { live in
                live.controller.commitCommandState(ifToken: nil) { $0.pendingPlanApprovalPlanID = nil }
            }
            try ensureLifecycleOperationLive(operation)
            // The remaining replay belongs to the same fenced incarnation.
            if replayHistory,
               let snapshot = await sessionRunner.snapshotSession(id: sessionID) {
                try ensureLifecycleOperationLive(operation)
                await replaySessionHistory(snapshot)
            }
            try ensureLifecycleOperationLive(operation)
            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
            )
            // The reply is written, so a close or shutdown that lands now owes
            // it nothing: a second response for the same id is never written,
            // and neither is an update for a session that is gone.
            guard isLifecycleOperationLive(operation) else {
                return
            }
            await sendSessionInfoUpdate(
                sessionID: sessionID,
                title: URL(fileURLWithPath: session.cwd).lastPathComponent
            )
            // A restore of a live id is a new presentation boundary: the plan
            // the client shows again is the graph's, whatever this incarnation
            // had presented before.
            await publishTaskGraphPlan(sessionID: sessionID, epoch: session.epoch, force: true)
            return
        }

        // The id is claimed here, in the same synchronous step that found it not
        // live: a second `session/load` or `session/resume` of the same id while
        // this one opens it would open a second incarnation, whose host slot,
        // MCP servers, and task-graph observer would be orphaned by the entry
        // the last one publishes. The claim is released by the `defer` on every
        // exit — success, error, close, shutdown — and a close or a delete of
        // the id invalidates the operation, so this restore answers with an
        // error after cleaning its own incarnation up.
        guard reserveSessionRestore(sessionID, operation: operation) else {
            throw ACPError.invalidParams(Self.sessionRestoreBusyMessage(sessionID))
        }
        defer { releaseSessionRestore(sessionID, operation: operation) }
        let rawCwd = Self.workingDirectory(from: params)
            ?? configuration.workingDirectory.path
        let workingDirectory = AgentConfiguration.resolvedWorkingDirectory(
            rawValue: rawCwd,
            applyLaunchDirectoryFallback: false
        )
        try ensureLifecycleOperationLive(operation)
        // The saved session of this id, unless the client sends its own
        // history, which wins. Read before the agent is resolved: the agent
        // decides the session's tool grant. The read does not suspend.
        let savedSession = Self.runtimeHistory(from: params["history"]).isEmpty
            ? savedACPSession(id: sessionID, workingDirectory: workingDirectory)
            : nil
        // Resolved before the incarnation opens, as `session/new` does: an
        // agent that cannot be resolved fails the restore before any MCP
        // server is installed.
        let selectedAgent = try resolvedACPAgentProfile(
            from: params,
            workingDirectory: workingDirectory,
            savedAgentID: savedSession?.agentID,
            savedAgentName: savedSession?.agentName
        )
        try ensureLifecycleOperationLive(operation)
        let restoredSessionEpoch = try await withNewIncarnation(
            sessionID: sessionID,
            cwd: workingDirectory.path,
            params: params,
            operation: operation
        ) { incarnation, acpMCPServers in
            let restored = await restoredACPClientSessionConfiguration(
                sessionID: sessionID,
                params: params,
                workingDirectory: workingDirectory,
                acpMCPServers: acpMCPServers,
                selectedAgent: selectedAgent,
                savedSession: savedSession
            )
            let configuration = restored.configuration
            try ensureLifecycleOperationLive(operation)
            // Past the last fence the session entry, the runner session, the
            // history replay and the reply become observable. The saved
            // session the incarnation was restored from is the one its saves
            // update.
            try publishNewIncarnation(
                incarnation,
                sessionID: sessionID,
                configuration: configuration,
                selectedAgent: selectedAgent,
                baseAllowedToolNames: restored.baseAllowedToolNames,
                savedSessionLink: savedSession.map {
                    ACPSavedSessionLink(
                        name: $0.name,
                        createdAt: $0.createdAt,
                        checkpointTree: $0.checkpointTree
                    )
                },
                promptDisplayTexts: savedSession.map(Self.promptDisplayTexts(restoring:)) ?? [:],
                operation: operation
            )
            try await sessionRunner.restoreSession(configuration: configuration)
            try await ensureLifecycleOperationLiveAfterSessionWrite(
                operation,
                sessionID: sessionID
            )
            if replayHistory {
                await replaySessionHistory(
                    AgentRuntimeSessionSnapshot(
                        sessionID: configuration.sessionID,
                        modelID: configuration.modelID,
                        workingDirectoryPath: configuration.workingDirectoryPath,
                        systemPrompt: configuration.systemPrompt,
                        dynamicContext: configuration.dynamicContext,
                        cacheKey: configuration.cacheKey,
                        history: configuration.history,
                        allowedToolNames: configuration.allowedToolNames,
                        thinkingSelection: configuration.thinkingSelection,
                        preserveThinking: configuration.preserveThinking
                    )
                )
                try ensureLifecycleOperationLive(operation)
            }
            return incarnation.epoch
        }
        try ensureLifecycleOperationLive(operation)

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        // The reply is written: as in the restore of a live id, a close or
        // shutdown that lands now writes no second response for this request
        // and no update for a session that is gone.
        guard isLifecycleOperationLive(operation) else {
            return
        }
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: workingDirectory.lastPathComponent
        )
        await publishAvailableCommands(sessionID: sessionID, epoch: restoredSessionEpoch)
        // Started after the reply, as in `session/new`: the session exists for
        // the client before its first `plan`, and a graph restored with the
        // session is published as the observer's first section.
        await startTaskGraphObserverIfNeeded(sessionID: sessionID, epoch: restoredSessionEpoch)
    }

    public static func sessionID(from params: [String: Any]) -> String? {
        for key in ["sessionId", "session_id", "id"] {
            if let value = (params[key] as? String)?.nilIfBlank {
                return value
            }
        }
        return nil
    }

    public static func modelID(from params: [String: Any]) -> String? {
        if let value = (params["modelId"] as? String)?.nilIfBlank
            ?? (params["modelID"] as? String)?.nilIfBlank
            ?? (params["model_id"] as? String)?.nilIfBlank
            ?? (params["currentModelId"] as? String)?.nilIfBlank
            ?? (params["current_model_id"] as? String)?.nilIfBlank
            ?? (params["model"] as? String)?.nilIfBlank {
            return value
        }
        if let config = params["config"] as? [String: Any],
           let value = (config["model"] as? String)?.nilIfBlank
               ?? (config["modelId"] as? String)?.nilIfBlank
               ?? (config["model_id"] as? String)?.nilIfBlank {
            return value
        }
        if let models = params["models"] as? [String: Any] {
            return (models["currentModelId"] as? String)?.nilIfBlank
                ?? (models["current_model_id"] as? String)?.nilIfBlank
        }
        return nil
    }

    /// The configuration of a restored session that is not live. Its history
    /// is the client's `history`, else the one of `savedSession`, the saved
    /// session of its id (`nil` when the client sent a history), without the
    /// dynamic context leading it. What the client asks for wins over the
    /// saved session, and the saved session over the defaults: the model is
    /// the client's `modelId`, else the saved one while the catalog still
    /// offers it, else the default; the thinking level is the client's, else
    /// the saved one when the chosen model offers it, else the resolved
    /// default; `preserveThinking` is the client's, else `false`. The system
    /// prompt, the dynamic context, the tool grant, and the cache key are
    /// composed as for any restore, never read from the file.
    func restoredACPClientSessionConfiguration(
        sessionID: String,
        params: [String: Any],
        workingDirectory: URL,
        acpMCPServers: ACPProvidedMCPServers,
        selectedAgent: AgentProfile?,
        savedSession: TerminalSavedSession?
    ) async -> (configuration: AgentCoreSessionConfiguration, baseAllowedToolNames: Set<String>?) {
        let requestedModelID = Self.modelID(from: params)
        let savedModelID = requestedModelID == nil
            ? savedSession?.modelID.flatMap { modelCatalog.containsModel(withID: $0) ? $0 : nil }
            : nil
        let modelID = requestedModelID
            ?? savedModelID
            ?? defaultSessionModelID(for: selectedAgent)
        let requestedAllowedToolNames = Self.allowedToolNames(from: params)
            ?? selectedAgent?.allowedToolNames()
        let resolvedRequestedAllowedToolNames = await resolvedAllowedToolNames(
            requestedAllowedToolNames,
            workingDirectory: workingDirectory
        )
        let baseAllowedToolNames = Self.sessionBaseAllowedToolNames(
            resolvedRequestedAllowedToolNames,
            adding: acpMCPServers
        )
        let allowedToolNames = Self.narrowedSessionAllowedToolNames(
            baseAllowedToolNames,
            selectedAgent: selectedAgent
        )
        let promptSections = resolvedPromptSections(
            providedSystemPrompt: nil,
            cwd: workingDirectory.path,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent
        )
        let requestedThinkingSelection = Self.thinkingSelection(from: params["thinkingSelection"])
        let savedThinkingSelection = requestedThinkingSelection == nil
            ? savedSession?.thinkingSelection.flatMap {
                modelCatalog.validatedThinkingSelection($0, forModelID: modelID)
            }
            : nil
        // A model restored from the saved session stands where the client's
        // model would: the default level is resolved for it.
        let thinkingSelection = savedThinkingSelection ?? modelCatalog.resolvedThinkingSelection(
            requested: requestedThinkingSelection,
            explicitModelID: requestedModelID ?? savedModelID ?? configuration.modelID,
            agentModelID: selectedAgent?.modelID,
            agentThinkingSelection: selectedAgent?.thinkingSelection,
            selectedModelID: modelID
        )
        let cacheKey = (params["sessionKey"] as? String)
            ?? (params["cacheKey"] as? String)
        let preserveThinking = (params["preserveThinking"] as? Bool)
            ?? (params["preserve_thinking"] as? Bool)
            ?? false
        let clientHistory = Self.runtimeHistory(from: params["history"])
        let history = clientHistory.isEmpty
            ? savedSession.map { AgentRuntimeDynamicContext.separating(from: $0.history).history } ?? []
            : clientHistory

        return (AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            agentID: selectedAgent?.id,
            agentName: selectedAgent?.name,
            agentRole: selectedAgent?.role,
            workingDirectory: workingDirectory,
            systemPrompt: promptSections.systemPrompt,
            dynamicContext: promptSections.dynamicContext,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            appMode: configuration.appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        ), baseAllowedToolNames)
    }

    public func sessionLifecycleResult(sessionID: String) -> [String: Any] {
        let session = sessions[sessionID]
        let sessionConfiguration = session?.configuration
        let modelID = sessionConfiguration?.modelID
            ?? defaultSessionModelID()
        var result: [String: Any] = [
            "sessionId": sessionID,
            "modes": [
                "availableModes": [
                    [
                        "id": "default",
                        "name": "Default",
                        "description": "Use the configured ZenCODE agent runtime."
                    ],
                    [
                        "id": "chat",
                        "name": "Chat",
                        "description": "Alias for the default ZenCODE agent runtime."
                    ]
                ],
                "currentModeId": "default"
            ],
            "configOptions": configOptions(
                for: modelID,
                thinkingSelection: sessionConfiguration?.thinkingSelection
            ),
            "_meta": [
                "models": modelState(for: modelID)
            ]
        ]
        if let selectedAgent = session?.selectedAgent {
            result["agentId"] = selectedAgent.id
            result["agentName"] = selectedAgent.name
        }
        return result
    }

}
