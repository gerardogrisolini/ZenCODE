//
//  ZenCODEACPBridge+SessionState.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension ZenCODEACPBridge {
    /// The models ACP sessions choose from: the host's models, or the user's
    /// configured catalog read on every use. Shared with the other channels.
    var modelCatalog: ChatModelCatalog {
        ChatModelCatalog(hostedModels: configuration.hostedModels)
    }

    /// The model a new session defaults to (see
    /// ``ChatModelCatalog/defaultModelID(explicitModelID:agentModelID:launchModelID:)``):
    /// with hosted models the launch-time model, otherwise `--model`, the
    /// launch agent's model, then the selected model, read from the settings
    /// now, so a model saved by `set_model` becomes the next default.
    func defaultSessionModelID() -> String? {
        modelCatalog.defaultModelID(
            explicitModelID: configuration.modelID,
            agentModelID: configuration.selectedAgent?.modelID,
            launchModelID: configuration.effectiveModelID
        )
    }

    public func configOptions(
        for modelID: String?,
        thinkingSelection: AgentThinkingSelection? = nil
    ) -> [[String: Any]] {
        let modelOptions = modelConfigOptions()
        guard !modelOptions.isEmpty else {
            return []
        }
        let selectedModelID = modelID?.nilIfBlank
            ?? defaultSessionModelID()?.nilIfBlank
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
                "category": "thought_level",
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
        ChatModelCatalog.thinkingOptions(for: model).map { selection in
            [
                "value": selection.rawValue,
                "name": selection.displayTitle,
                "description": selection.menuTitle
            ]
        }
    }

    public func availableModelManifests() -> [AgentSettingsModelManifest] {
        modelCatalog.availableModels()
    }

    public func modelManifest(for modelID: String?) -> AgentSettingsModelManifest? {
        modelCatalog.model(matching: modelID)
    }

    public func modelState(for modelID: String?) -> [String: Any] {
        let modelOptions = modelConfigOptions()
        let selectedModelID = modelID?.nilIfBlank
            ?? defaultSessionModelID()?.nilIfBlank
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

    /// The ACP state of a new incarnation the host runs: unannounced, with
    /// fresh presentation state, no companion, and no prompt.
    func sessionState(
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile? = nil,
        incarnation: ChatSessionIncarnation
    ) -> SessionState {
        SessionState(
            id: configuration.sessionID,
            cwd: configuration.workingDirectory.path,
            allowedToolNames: configuration.allowedToolNames,
            configuration: configuration,
            epoch: incarnation.epoch,
            slotID: incarnation.slotID,
            selectedAgent: selectedAgent,
            controller: incarnation.controller
        )
    }

    /// The ACP state of the live incarnation `live` with another
    /// configuration. All same-incarnation reconstruction paths (mention,
    /// refresh and reconfiguration) inherit the ACP presentation state, the
    /// incarnation binding (its slot, epoch, and controller with its command
    /// state), the registered prompt task, and the Telegram companion from
    /// the live entry. A new epoch, including load/resume, deliberately
    /// starts unannounced with a new controller and without a companion
    /// (``sessionState(configuration:selectedAgent:incarnation:)``).
    func sessionState(
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile? = nil,
        inheriting live: SessionState
    ) -> SessionState {
        SessionState(
            id: configuration.sessionID,
            cwd: configuration.workingDirectory.path,
            allowedToolNames: configuration.allowedToolNames,
            configuration: configuration,
            epoch: live.epoch,
            slotID: live.slotID,
            selectedAgent: selectedAgent,
            hasPresentedInitialConfiguration: live.hasPresentedInitialConfiguration,
            presentedCommands: live.presentedCommands,
            promptUpdatePipeline: live.promptUpdatePipeline,
            delegatedToolNotifications: live.delegatedToolNotifications,
            tasklessObserver: live.tasklessObserver,
            tasklessPresentation: live.tasklessPresentation,
            taskPresentation: live.taskPresentation,
            activeWorkflowPromptID: live.activeWorkflowPromptID,
            activePromptTask: live.activePromptTask,
            activePromptTaskID: live.activePromptTaskID,
            controller: live.controller,
            telegramCompanion: live.telegramCompanion,
            telegramCompanionChannel: live.telegramCompanionChannel
        )
    }

    /// Runs a new incarnation of `configuration.sessionID` in the host and
    /// publishes its ACP state: what `session/new` and `session/load` do
    /// between their fences, in one step, for the tests that install a
    /// session directly. The runner session is not created. An entry of an
    /// earlier incarnation with the same id is replaced and its slot closed,
    /// as a close followed by a load of the same id would leave it.
    func installSession(
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile? = nil
    ) async throws -> SessionState {
        if let replaced = sessions.removeValue(forKey: configuration.sessionID) {
            await host.closeSlot(replaced.slotID, runtimeSession: .keep)
        }
        let incarnation = try await openACPSession(
            sessionID: configuration.sessionID,
            cwd: configuration.workingDirectory.path
        )
        let state = sessionState(
            configuration: configuration,
            selectedAgent: selectedAgent,
            incarnation: incarnation
        )
        sessions[configuration.sessionID] = state
        return state
    }

    /// Describes the selected runtime configuration without resolving a new
    /// thinking value or injecting presentation metadata into the model turn.
    func initialConfigurationSummary(for session: SessionState) -> String {
        initialConfigurationSummary(
            configuration: session.configuration,
            selectedAgent: session.selectedAgent
        )
    }

    func initialConfigurationSummary(
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile?
    ) -> String {
        let agent = selectedAgent?.name.nilIfBlank
            ?? configuration.agentName?.nilIfBlank
            ?? configuration.agentID?.nilIfBlank
            ?? "Default"
        let model = configuration.modelID?.nilIfBlank ?? "Default"
        let thinking: String
        if let selection = configuration.thinkingSelection {
            thinking = selection.displayTitle
        } else if modelManifest(for: configuration.modelID)?.supportsThinking == false {
            thinking = "Not supported"
        } else {
            // Missing/unknown capability is not evidence that thinking is off.
            thinking = "Default"
        }
        return "Agent: \(agent) · Model: \(model) · Thinking: \(thinking)\n\n"
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
            agentRole: configuration.agentRole,
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
        let epoch = existingSession.epoch
        // The prompt reservation is the host's: a refresh bound to a prompt
        // runs only while that prompt still holds its incarnation.
        if let expectedPromptID {
            guard await host.holdsPrompt(existingSession.promptReservation(expectedPromptID)) else {
                return
            }
        }
        guard let snapshot = await sessionRunner.snapshotSession(id: sessionID) else {
            return
        }
        guard let session = liveSession(id: sessionID, epoch: epoch) else {
            return
        }
        if let expectedPromptID {
            guard await host.holdsPrompt(session.promptReservation(expectedPromptID)) else {
                return
            }
        }
        // Rebuild from the entry as it is after the last hop.
        updateLiveSession(id: sessionID, epoch: epoch) { live in
            live = sessionState(
                configuration: AgentCoreSessionConfiguration(
                    sessionID: snapshot.sessionID,
                    modelID: snapshot.modelID ?? configuration.effectiveModelID,
                    agentID: session.configuration.agentID,
                    agentName: session.configuration.agentName,
                    agentRole: session.configuration.agentRole,
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
                inheriting: live
            )
        }
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
                // Snapshots have no per-message provider provenance. The current
                // snapshot.modelID may follow a provider switch, so replay must
                // not apply the live ChatGPT formatter to possibly foreign text.
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
