//
//  ZenCODEACPBridge+SessionState.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

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

    public func sessionState(
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile? = nil,
        activePromptTask: Task<PromptCompletion, Error>? = nil
    ) -> SessionState {
        SessionState(
            id: configuration.sessionID,
            cwd: configuration.workingDirectory.path,
            allowedToolNames: configuration.allowedToolNames,
            configuration: configuration,
            selectedAgent: selectedAgent,
            activePromptTask: activePromptTask
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

    public static func verboseToolNameSummary(_ toolNames: Set<String>?) -> String {
        guard let toolNames else {
            return "all"
        }
        return verboseNameSummary(toolNames)
    }

    public static func verboseDescriptorSummary(_ descriptors: [DirectToolDescriptor]) -> String {
        verboseNameSummary(descriptors.map(\.name))
    }

    private static func verboseNameSummary<S: Sequence>(_ names: S) -> String where S.Element == String {
        let sortedNames = names.filter { !$0.isEmpty }.sorted()
        let sample = sortedNames.prefix(8).joined(separator: ",")
        let suffix = sortedNames.count > 8 ? ",..." : ""
        return "\(sortedNames.count)[\(sample)\(suffix)]"
    }

    public func sessionConfiguration(
        from configuration: AgentCoreSessionConfiguration,
        allowedToolNames: Set<String>?
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: configuration.sessionID,
            modelID: configuration.modelID,
            bearerToken: configuration.bearerToken,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: configuration.systemPrompt,
            cacheKey: configuration.cacheKey,
            sessionRevision: configuration.sessionRevision,
            history: configuration.history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: configuration.configuredContextWindowLimit,
            generationParameterOverrides: configuration.generationParameterOverrides,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: configuration.appMode,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    public func refreshSessionStateIfAvailable(sessionID: String) async {
        guard let snapshot = await sessionRunner.snapshotSession(id: sessionID) else {
            return
        }
        guard let session = sessions[sessionID] else {
            return
        }
        sessions[sessionID] = sessionState(
            configuration: AgentCoreSessionConfiguration(
                sessionID: snapshot.sessionID,
                modelID: snapshot.modelID ?? configuration.effectiveModelID,
                bearerToken: configuration.bearerToken,
                workingDirectory: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt,
                cacheKey: snapshot.cacheKey,
                history: snapshot.history,
                allowedToolNames: snapshot.allowedToolNames,
                maxToolRounds: configuration.maxToolRounds,
                maxOutputTokens: configuration.maxOutputTokens,
                verboseLogging: configuration.verboseLogging,
                appMode: configuration.appMode,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            ),
            selectedAgent: session.selectedAgent,
            activePromptTask: session.activePromptTask
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
                        update: JSONValue.acpValue(from: [
                            "sessionUpdate": "agent_thought_chunk",
                            "content": [
                                "type": "text",
                                "text": thought
                            ]
                        ])
                    )
                }
                guard let text = message.content.nilIfBlank else {
                    continue
                }
                await writer.sendSessionUpdate(
                    sessionID: snapshot.sessionID,
                    update: JSONValue.acpValue(from: [
                        "sessionUpdate": "agent_message_chunk",
                        "content": [
                            "type": "text",
                            "text": text
                        ]
                    ])
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
