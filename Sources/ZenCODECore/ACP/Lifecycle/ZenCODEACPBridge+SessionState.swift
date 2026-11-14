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
    /// fresh presentation state and no prompt.
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
    /// state) and the registered prompt task from the live entry. A new
    /// epoch, including load/resume, deliberately starts unannounced with a
    /// new controller (``sessionState(configuration:selectedAgent:incarnation:)``);
    /// the slot's Telegram channel, if any, belongs to the slot and follows
    /// it by itself.
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
            savedSessionLink: live.savedSessionLink,
            controller: live.controller
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
        // Rebuild from the entry as it is after the last hop. The model, like
        // the profile and the model settings, stays the session's own (see
        // `AgentCoreSessionConfiguration.replacingRuntimeState(with:)`): a
        // backend reports the id it speaks on the wire (`claude-fable-5-2`
        // for `claude:claude-fable-5-2`). Adopting it would make the next
        // prompt's configuration fail `matchesRuntime`, so the backend would
        // be built again (its features discovering their tools, and asking
        // for their consent, again) for an id that no longer names the
        // session's provider and may resolve to another provider's model.
        let didRefresh = updateLiveSession(id: sessionID, epoch: epoch) { live in
            live = sessionState(
                configuration: AgentCoreSessionConfiguration(
                    sessionID: snapshot.sessionID,
                    modelID: session.configuration.modelID,
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
        // The live session now holds the turn's history: so does its saved
        // session, for `/sessions` and for a `session/load` after the process
        // restarted. Saved only when the refresh took place, for the same
        // incarnation.
        if didRefresh {
            await saveSession(sessionID: sessionID, epoch: epoch, snapshot: snapshot)
        }
    }

    /// Replays `snapshot`'s history to the client (`session/load`,
    /// `session/resume`): the log entries rebuilt from it
    /// (``ChatTurnEntry/kinds(fromTranscript:)``, the one rebuild every
    /// channel shares), rendered as the editor's chunks. A prompt is a
    /// `user_message_chunk` (a blank prompt with attachments says so), a
    /// block its `agent_thought_chunk` and `agent_message_chunk`; tool calls,
    /// their results, and system messages are not replayed.
    public func replaySessionHistory(_ snapshot: AgentRuntimeSessionSnapshot) async {
        for kind in ChatTurnEntry.kinds(fromTranscript: snapshot.history) {
            switch kind {
            case let .userPrompt(text, attachments, _):
                guard let text = Self.replayText(prompt: text, attachments: attachments) else {
                    continue
                }
                await sendUserMessageChunk(sessionID: snapshot.sessionID, text: text)
            case let .thought(thought):
                // Snapshots have no per-message provider provenance. The current
                // snapshot.modelID may follow a provider switch, so replay must
                // not apply the live ChatGPT formatter to possibly foreign text.
                // A thought entry is trimmed and never blank.
                await writer.sendSessionUpdate(
                    sessionID: snapshot.sessionID,
                    update: Self.textChunkJSONUpdate(kind: "agent_thought_chunk", text: thought)
                )
            case let .assistantText(content):
                guard let text = content.nilIfBlank else {
                    continue
                }
                await writer.sendSessionUpdate(
                    sessionID: snapshot.sessionID,
                    update: Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: text)
                )
            default:
                continue
            }
        }
    }

    /// The text a replayed prompt shows: the prompt, or, for a blank prompt
    /// with attachments, a request to analyze them; `nil` for a blank prompt
    /// without attachments.
    private static func replayText(prompt: String, attachments: [AgentRuntimeAttachment]) -> String? {
        if let content = prompt.nilIfBlank {
            return content
        }
        guard !attachments.isEmpty else {
            return nil
        }
        return "Analyze the attached media."
    }

}
