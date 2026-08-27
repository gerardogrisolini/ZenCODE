//
//  ZenCODEACPBridge+SessionState.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension ZenCODEACPBridge {
    public func configOptions(
        for modelID: String?,
        thinkingSelection: AgentThinkingSelection? = nil
    ) -> [[String: Any]] {
        let modelOptions = modelConfigOptions()
        guard !modelOptions.isEmpty else {
            return []
        }
        let selectedModelID = modelID?.nilIfBlank
            ?? configuration.effectiveModelID?.nilIfBlank
            ?? (modelOptions.first?["value"] as? String)
            ?? ""
        var options: [[String: Any]] = [
            [
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": selectedModelID,
                "options": modelOptions
            ]
        ]

        if let model = modelManifest(for: selectedModelID), model.supportsThinking {
            let selectedThinking = model.thinkingSelection(for: thinkingSelection)
            options.append([
                "id": "thinking",
                "name": "Thinking",
                "category": "model",
                "type": "select",
                "currentValue": selectedThinking?.rawValue ?? "",
                "options": thinkingConfigOptions(for: model)
            ])
        }
        return options
    }

    public func modelConfigOptions() -> [[String: Any]] {
        availableModelManifests().map { model in
            [
                "value": model.id,
                "name": model.displayTitle,
                "description": model.modelID
            ]
        }
    }

    public func thinkingConfigOptions(
        for model: AgentSettingsModelManifest
    ) -> [[String: Any]] {
        model.availableThinkingSelections.map { selection in
            [
                "value": selection.rawValue,
                "name": selection.displayTitle,
                "description": selection.menuTitle
            ]
        }
    }

    public func availableModelManifests() -> [AgentSettingsModelManifest] {
        configuration.hostedModels ?? AgentSettingsStore.availableModels()
    }

    public func modelManifest(for modelID: String?) -> AgentSettingsModelManifest? {
        guard let modelID = modelID?.nilIfBlank else {
            return nil
        }
        return availableModelManifests().first { model in
            model.matches(modelID)
        }
    }

    public func modelState(for modelID: String?) -> [String: Any] {
        let modelOptions = modelConfigOptions()
        let selectedModelID = modelID?.nilIfBlank
            ?? configuration.effectiveModelID?.nilIfBlank
            ?? (modelOptions.first?["value"] as? String)
            ?? ""
        return [
            "currentModelId": selectedModelID,
            "availableModels": modelOptions.map { option in
                [
                    "modelId": option["value"] as? String ?? "",
                    "name": option["name"] as? String ?? "",
                    "description": option["description"] as? String ?? ""
                ]
            }
        ]
    }

    /// Builds a session state with a fresh epoch. Pass `epoch` to preserve the
    /// existing incarnation when only refreshing an already-live session.
    public func sessionState(
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile? = nil,
        epoch: UInt64? = nil,
        activePromptID: UUID? = nil,
        activePromptTask: Task<PromptCompletion, Error>? = nil,
        operationState: SessionOperationState = .idle
    ) -> SessionState {
        sessionStateWithCommandState(
            configuration: configuration,
            selectedAgent: selectedAgent,
            epoch: epoch,
            activePromptID: activePromptID,
            activePromptTask: activePromptTask,
            operationState: operationState
        )
    }

    func sessionStateWithCommandState(
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile? = nil,
        epoch: UInt64? = nil,
        activePromptID: UUID? = nil,
        activePromptTask: Task<PromptCompletion, Error>? = nil,
        operationState: SessionOperationState = .idle,
        activePlan: TerminalSessionPlan? = nil,
        planBrainstorming: PlanningCommandRuntimeState? = nil,
        workflowContinuation: WorkflowCommandRuntimeState? = nil
    ) -> SessionState {
        SessionState(
            id: configuration.sessionID,
            cwd: configuration.workingDirectory.path,
            allowedToolNames: configuration.allowedToolNames,
            configuration: configuration,
            epoch: epoch ?? makeSessionEpoch(),
            selectedAgent: selectedAgent,
            activePromptID: activePromptID,
            activePromptTask: activePromptTask,
            operationState: operationState,
            activePlan: activePlan,
            planBrainstorming: planBrainstorming,
            workflowContinuation: workflowContinuation
        )
    }

    public static func allowedToolNames(
        _ allowedToolNames: Set<String>?,
        adding descriptors: [DirectToolDescriptor]
    ) -> Set<String>? {
        let descriptorNames = Set(descriptors.map(\.name).filter { !$0.isEmpty })
        guard !descriptorNames.isEmpty else {
            return allowedToolNames
        }
        var merged = allowedToolNames ?? []
        merged.formUnion(descriptorNames)
        return merged
    }

    public func sessionConfiguration(
        from configuration: AgentCoreSessionConfiguration,
        allowedToolNames: Set<String>?
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: configuration.sessionID,
            modelID: configuration.modelID,
            agentID: configuration.agentID,
            agentName: configuration.agentName,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: configuration.systemPrompt,
            dynamicContext: configuration.dynamicContext,
            cacheKey: configuration.cacheKey,
            sessionRevision: configuration.sessionRevision,
            history: configuration.history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: configuration.configuredContextWindowLimit,
            generationParameterOverrides: configuration.generationParameterOverrides,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            appMode: configuration.appMode,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    public func refreshSessionStateIfAvailable(
        sessionID: String,
        preservingAllowedToolNames allowedToolNames: Set<String>? = nil,
        expectedEpoch: UInt64? = nil,
        expectedPromptID: UUID? = nil
    ) async {
        // Capture the incarnation before suspending so a close/shutdown that
        // lands during the snapshot read cannot be undone by this refresh.
        guard let existingSession = sessions[sessionID] else {
            return
        }
        if let expectedEpoch, existingSession.epoch != expectedEpoch {
            return
        }
        if let expectedPromptID,
           existingSession.activePromptID != expectedPromptID {
            return
        }
        let epoch = existingSession.epoch
        guard let snapshot = await sessionRunner.snapshotSession(id: sessionID) else {
            return
        }
        guard let session = liveSession(id: sessionID, epoch: epoch) else {
            return
        }
        if let expectedPromptID, session.activePromptID != expectedPromptID {
            return
        }
        sessions[sessionID] = sessionStateWithCommandState(
            configuration: AgentCoreSessionConfiguration(
                sessionID: snapshot.sessionID,
                modelID: snapshot.modelID ?? configuration.effectiveModelID,
                agentID: session.configuration.agentID,
                agentName: session.configuration.agentName,
                workingDirectory: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt,
                dynamicContext: snapshot.dynamicContext,
                cacheKey: snapshot.cacheKey,
                sessionRevision: session.configuration.sessionRevision,
                history: snapshot.history,
                allowedToolNames: allowedToolNames ?? snapshot.allowedToolNames,
                configuredContextWindowLimit: session.configuration.configuredContextWindowLimit,
                generationParameterOverrides: session.configuration.generationParameterOverrides,
                maxToolRounds: configuration.maxToolRounds,
                maxOutputTokens: configuration.maxOutputTokens,
                appMode: configuration.appMode,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            ),
            selectedAgent: session.selectedAgent,
            epoch: session.epoch,
            activePromptID: session.activePromptID,
            activePromptTask: session.activePromptTask,
            operationState: session.operationState,
            activePlan: session.activePlan,
            planBrainstorming: session.planBrainstorming,
            workflowContinuation: session.workflowContinuation
        )
    }

    public func replaySessionHistory(_ snapshot: AgentRuntimeSessionSnapshot) async {
        for message in snapshot.history {
            switch message.role {
            case .user:
                let text = replayText(for: message)
                guard let text else {
                    continue
                }
                await sendUserMessageChunk(sessionID: snapshot.sessionID, text: text)
            case .assistant:
                if let thought = message.reasoningContent?.nilIfBlank {
                    await writer.sendSessionUpdate(
                        sessionID: snapshot.sessionID,
                        update: Self.textChunkJSONUpdate(kind: "agent_thought_chunk", text: thought)
                    )
                }
                guard let text = message.content.nilIfBlank else {
                    continue
                }
                await writer.sendSessionUpdate(
                    sessionID: snapshot.sessionID,
                    update: Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: text)
                )
            case .system, .tool:
                continue
            }
        }
    }

    private func replayText(for message: AgentRuntimeMessage) -> String? {
        if let content = message.content.nilIfBlank {
            return content
        }
        guard !message.attachments.isEmpty else {
            return nil
        }
        return "Analyze the attached media."
    }

}
