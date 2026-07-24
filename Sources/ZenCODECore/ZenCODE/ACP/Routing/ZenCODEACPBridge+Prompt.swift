//
//  ZenCODEACPBridge+Prompt.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

extension ZenCODEACPBridge {
    public func prompt(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = Self.sessionID(from: params),
              var session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard session.activePromptTask == nil else {
            throw ACPError.invalidParams("A prompt is already running for this session.")
        }

        let promptBlocks = promptBlocks(from: params)
        let rawPromptText = PromptContentFormatter.renderPromptText(from: promptBlocks)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = Self.promptAttachments(
            from: promptBlocks,
            renderedPromptText: rawPromptText,
            cwd: session.cwd
        )
        let promptText = rawPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentMentionResolution = try resolveLeadingACPAgentMention(in: promptText)
        let routedPromptText = agentMentionResolution?.prompt ?? promptText
        guard !routedPromptText.isEmpty || !attachments.isEmpty else {
            throw ACPError.invalidParams("session/prompt requires prompt text or attachments.")
        }

        let promptConfiguration: AgentCoreSessionConfiguration
        if let agentMentionResolution {
            promptConfiguration = await acpSessionConfiguration(
                applying: agentMentionResolution.agent,
                to: session.configuration
            )
            session = sessionState(
                configuration: promptConfiguration,
                selectedAgent: agentMentionResolution.agent
            )
        } else {
            promptConfiguration = session.configuration
        }
        if configuration.verboseLogging {
            let mcpDescriptors = await sessionRunner.knownMCPToolDescriptors(
                allowedToolNames: promptConfiguration.allowedToolNames,
                preferredWorkspaceRootURL: URL(fileURLWithPath: session.cwd)
            )
            await verboseACPLog(
                "session/prompt id=\(sessionID) knownMCPTools=\(Self.verboseDescriptorSummary(mcpDescriptors)) allowedTools=\(Self.verboseToolNameSummary(promptConfiguration.allowedToolNames))"
            )
        }

        let visiblePromptText = routedPromptText.isEmpty ? "Analyze the attached media." : routedPromptText
        await sendUserMessageChunk(sessionID: sessionID, text: visiblePromptText)
        await sendSessionInfoUpdate(sessionID: sessionID, title: promptTitle(from: visiblePromptText))

        let writer = self.writer
        let appMode = configuration.appMode
        let updateBuffer = appMode ? ACPPromptUpdateBuffer() : nil
        let sessionRunner = self.sessionRunner

        @Sendable func sendPromptUpdate(_ update: JSONValue) async {
            if let updateBuffer {
                for bufferedUpdate in updateBuffer.consume(update) {
                    await writer.sendSessionUpdate(
                        sessionID: sessionID,
                        update: bufferedUpdate
                    )
                }
            } else {
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: update
                )
            }
        }

        func flushPromptUpdates() async {
            guard let updateBuffer else {
                return
            }
            for update in updateBuffer.flushAll() {
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: update
                )
            }
        }

        let activePromptTask = Task {
            await sessionRunner.updatePromptSkillSelection(
                selectedAgentSkills(for: session.selectedAgent),
                sessionID: promptConfiguration.sessionID
            )
            let response = try await sessionRunner.sendPrompt(
                configuration: promptConfiguration,
                prompt: routedPromptText,
                attachments: attachments,
                toolProviders: [],
                onEvent: { event in
                    switch event {
                    case let .status(message):
                        if !appMode {
                            await sendPromptUpdate(JSONValue.acpValue(from: [
                                "sessionUpdate": "agent_thought_chunk",
                                "content": [
                                    "type": "text",
                                    "text": message
                                ]
                            ]))
                        }
                    case let .diagnostic(message):
                        await self.verboseACPLog("diagnostic \(message)")
                        if Self.isMetricsDiagnostic(message) {
                            break
                        }
                        if !appMode || !Self.isAppSuppressedDiagnostic(message) {
                            await sendPromptUpdate(JSONValue.acpValue(from: [
                                "sessionUpdate": "agent_thought_chunk",
                                "content": [
                                    "type": "text",
                                    "text": message
                                ]
                            ]))
                        }
                    case let .thought(message):
                        await sendPromptUpdate(JSONValue.acpValue(from: [
                            "sessionUpdate": "agent_thought_chunk",
                            "content": [
                                "type": "text",
                                "text": message
                            ]
                        ]))
                    case let .modelLoaded(modelID):
                        if !appMode {
                            await sendPromptUpdate(JSONValue.acpValue(from: [
                                "sessionUpdate": "agent_thought_chunk",
                                "content": [
                                    "type": "text",
                                    "text": "Loaded model: \(modelID)"
                                ]
                            ]))
                        }
                    case .metrics:
                        break
                    case let .contextWindow(status):
                        if let update = Self.usageUpdate(for: status) {
                            await sendPromptUpdate(JSONValue.acpValue(from: update))
                        }
                    case let .subscriptionUsage(status):
                        if let update = Self.subscriptionUsageUpdate(for: status) {
                            await sendPromptUpdate(JSONValue.acpValue(from: update))
                        }
                    case let .content(content):
                        await sendPromptUpdate(JSONValue.acpValue(from: [
                            "sessionUpdate": "agent_message_chunk",
                            "content": [
                                "type": "text",
                                "text": content
                            ]
                        ]))
                    case let .toolCallStarted(toolCall):
                        await sendPromptUpdate(JSONValue.acpValue(from: Self.toolCallCreateUpdate(for: toolCall)))
                        await sendPromptUpdate(JSONValue.acpValue(from: Self.toolCallProgressUpdate(for: toolCall)))
                    case let .toolCallCompleted(toolCall, result):
                        await sendPromptUpdate(
                            JSONValue.acpValue(from: Self.toolCallCompletionUpdate(
                                for: toolCall,
                                result: result
                            ))
                        )
                    case .sessionSnapshot,
                         .turnEnded:
                        break
                    }
                }
            )
            return PromptCompletion(
                text: response.text,
                stopReason: Self.acpStopReason(response.stopReason)
            )
        }

        session.activePromptTask = activePromptTask
        sessions[sessionID] = session

        do {
            let completion = try await activePromptTask.value
                        await flushPromptUpdates()
            await refreshSessionStateIfAvailable(sessionID: sessionID)
            var refreshedSession = sessions[sessionID] ?? session
            refreshedSession.activePromptTask = nil
            sessions[sessionID] = refreshedSession

            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: ["stopReason": completion.stopReason])
            )
        } catch is CancellationError {
            await flushPromptUpdates()
            await refreshSessionStateIfAvailable(sessionID: sessionID)
            sessions[sessionID]?.activePromptTask = nil
            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: ["stopReason": "cancelled"])
            )
        } catch {
            await flushPromptUpdates()
            await refreshSessionStateIfAvailable(sessionID: sessionID)
            sessions[sessionID]?.activePromptTask = nil
            throw error
        }
    }

    public static func acpStopReason(_ value: String?) -> String {
        switch value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "end_turn", "endturn":
            return "end_turn"
        case "max_tokens", "max_output_tokens", "length":
            return "max_tokens"
        case "max_turn_requests", "tool_round_limit", "too_many_tool_rounds":
            return "max_turn_requests"
        case "refusal", "content_filter", "safety":
            return "refusal"
        case "cancelled", "canceled", "cancel":
            return "cancelled"
        case "stop", "completed", "complete", "done", "tool_calls", "function_call", nil, "":
            return "end_turn"
        default:
            return "end_turn"
        }
    }

    public func cancel(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = Self.sessionID(from: params),
              var session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        session.activePromptTask?.cancel()
        session.activePromptTask = nil
        sessions[sessionID] = session
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    public func close(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = Self.sessionID(from: params) else {
            throw ACPError.invalidParams("session/close requires params.sessionId.")
        }
        sessions[sessionID]?.activePromptTask?.cancel()
        await refreshSessionStateIfAvailable(sessionID: sessionID)
        sessions.removeValue(forKey: sessionID)
        updateSessionSleepAssertion()
        await sessionRunner.closeSession(id: sessionID)
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    public func promptBlocks(from params: [String: Any]) -> [Any] {
        if let prompt = params["prompt"] as? [Any] {
            return prompt
        }
        if let content = params["content"] as? [Any] {
            return content
        }
        if let prompt = params["prompt"] as? String {
            return [
                [
                    "type": "text",
                    "text": prompt
                ] as [String: Any]
            ]
        }
        if let content = params["content"] as? String {
            return [
                [
                    "type": "text",
                    "text": content
                ] as [String: Any]
            ]
        }
        return []
    }

    public static func promptAttachments(
        from blocks: [Any],
        renderedPromptText _: String,
        cwd: String
    ) -> [AgentRuntimeAttachment] {
        var attachments: [AgentRuntimeAttachment] = []
        var seenKeys = Set<String>()

        func append(_ attachment: AgentRuntimeAttachment?) {
            guard let attachment else {
                return
            }
            let key = attachment.fileURL?.standardizedFileURL.path
                ?? "\(attachment.originalFilename):\(attachment.data?.count ?? 0)"
            guard seenKeys.insert(key).inserted else {
                return
            }
            attachments.append(attachment)
        }

        for block in blocks {
            append(promptAttachment(from: block, cwd: cwd))
        }
        return attachments
    }

    private static func promptAttachment(from block: Any, cwd: String) -> AgentRuntimeAttachment? {
        guard let object = block as? [String: Any] else {
            return nil
        }
        let type = stringValue(object["type"])?.lowercased() ?? "text"

        switch type {
        case "image", "input_image":
            return imageAttachment(from: object, cwd: cwd)
        case "image_url":
            return imageURLAttachment(from: object["image_url"], cwd: cwd)
        case "resource":
            guard let resource = object["resource"] as? [String: Any] else {
                return nil
            }
            return imageAttachment(from: resource, cwd: cwd)
        default:
            if let imageURL = object["image_url"] {
                return imageURLAttachment(from: imageURL, cwd: cwd)
            }
            return nil
        }
    }

    private static func imageAttachment(from object: [String: Any], cwd: String) -> AgentRuntimeAttachment? {
        let contentType = firstString(
            in: object,
            keys: ["mimeType", "mime_type", "mediaType", "media_type", "contentType", "content_type"]
        )
        let originalFilename = firstString(
            in: object,
            keys: ["filename", "fileName", "name", "title"]
        )
        if let data = firstBase64Data(in: object) {
            return AgentRuntimeAttachment(
                kind: .image,
                data: data,
                contentType: contentType,
                originalFilename: originalFilename
                    ?? embeddedAttachmentFilename(contentType: contentType)
            )
        }

        if let uri = firstString(in: object, keys: ["uri", "url", "path", "image_url"]),
           let attachment = imageURLAttachment(from: uri, cwd: cwd, contentType: contentType) {
            return attachment
        }
        return nil
    }

    private static func imageURLAttachment(
        from value: Any?,
        cwd: String,
        contentType: String? = nil
    ) -> AgentRuntimeAttachment? {
        let rawURL: String?
        if let string = value as? String {
            rawURL = string
        } else if let object = value as? [String: Any] {
            rawURL = firstString(in: object, keys: ["url", "uri", "path"])
        } else {
            rawURL = nil
        }

        guard let rawURL = rawURL?.nilIfBlank else {
            return nil
        }
        if let (mimeType, data) = imageDataURL(rawURL) {
            return AgentRuntimeAttachment(
                kind: .image,
                data: data,
                contentType: contentType ?? mimeType,
                originalFilename: embeddedAttachmentFilename(contentType: contentType ?? mimeType)
            )
        }
        guard let fileURL = fileURL(from: rawURL, cwd: cwd) else {
            return nil
        }
        return try? AgentRuntimeAttachmentStore.importFile(from: fileURL).runtimeAttachment
    }

    private static func firstBase64Data(in object: [String: Any]) -> Data? {
        for key in ["data", "blob", "base64", "bytes"] {
            guard let value = stringValue(object[key])?.nilIfBlank else {
                continue
            }
            if let (_, data) = imageDataURL(value) {
                return data
            }
            if let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) {
                return data
            }
        }
        return nil
    }

    private static func imageDataURL(_ value: String) -> (mimeType: String?, data: Data)? {
        guard value.lowercased().hasPrefix("data:"),
              let separatorRange = value.range(of: ";base64,") else {
            return nil
        }
        let mimeType = String(value[value.index(value.startIndex, offsetBy: 5)..<separatorRange.lowerBound])
            .nilIfBlank
        let base64 = String(value[separatorRange.upperBound...])
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return (mimeType, data)
    }

    private static func fileURL(from value: String, cwd: String) -> URL? {
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        guard !value.contains("://") else {
            return nil
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(value)
            .standardizedFileURL
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key])?.nilIfBlank {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        return nil
    }

    private static func embeddedAttachmentFilename(contentType: String?) -> String {
        let fileExtension = AgentRuntimeAttachmentStore.preferredFilenameExtension(
            originalFilename: "",
            contentType: contentType
        )
        return fileExtension.isEmpty ? "image" : "image.\(fileExtension)"
    }
}

private struct ACPAgentMentionResolution {
    let agent: AgentProfile
    let prompt: String
}

extension ZenCODEACPBridge {
    private func resolveLeadingACPAgentMention(in prompt: String) throws -> ACPAgentMentionResolution? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrompt.hasPrefix("@") else {
            return nil
        }

        let mentionBody = String(trimmedPrompt.dropFirst())
        let splitIndex = mentionBody.firstIndex { $0.isWhitespace }
            ?? mentionBody.endIndex
        let rawMention = String(mentionBody[..<splitIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mentionKey = Self.acpAgentMentionLookupKey(rawMention)
        guard !mentionKey.isEmpty else {
            return nil
        }

        let agents = try availableACPAgentProfiles()
        guard let agent = agents.first(where: { Self.acpAgentMentionLookupKeys(for: $0).contains(mentionKey) }) else {
            return nil
        }

        let remainingPrompt = String(mentionBody[splitIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ACPAgentMentionResolution(agent: agent, prompt: remainingPrompt)
    }

    func availableACPAgentProfiles() throws -> [AgentProfile] {
        if let hostedAgentProfiles = configuration.hostedAgentProfiles {
            return hostedAgentProfiles
        }
        return try AgentProfileStore.loadRequired()
    }

    func resolvedACPAgentProfile(from params: [String: Any]) throws -> AgentProfile? {
        let rawAgentReference = (params["agentId"] as? String)?.nilIfBlank
            ?? (params["agentID"] as? String)?.nilIfBlank
            ?? (params["agent_id"] as? String)?.nilIfBlank
            ?? (params["agentName"] as? String)?.nilIfBlank
            ?? (params["agent_name"] as? String)?.nilIfBlank
        guard let rawAgentReference else {
            return configuration.selectedAgent
        }

        let lookupKey = Self.acpAgentMentionLookupKey(rawAgentReference)
        guard let agent = try availableACPAgentProfiles().first(where: {
            Self.acpAgentMentionLookupKeys(for: $0).contains(lookupKey)
        }) else {
            throw ACPError.invalidParams("Unknown agent: \(rawAgentReference).")
        }
        return agent
    }

    func acpSessionConfiguration(
        applying agent: AgentProfile,
        to baseConfiguration: AgentCoreSessionConfiguration
    ) async -> AgentCoreSessionConfiguration {
        var allowedToolNames = await resolvedAllowedToolNames(
            agent.allowedToolNames(),
            workingDirectory: baseConfiguration.workingDirectory
        )
        if var effectiveAllowedToolNames = allowedToolNames {
            effectiveAllowedToolNames.formUnion(PromptSkillToolProvider.toolNames)
            allowedToolNames = effectiveAllowedToolNames
        }
        let modelID = agent.modelID ?? baseConfiguration.modelID
        let systemPrompt = AgentCoreAppSessionFactory.resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: baseConfiguration.workingDirectory.path,
            selectedAgent: agent,
            allowedToolNames: allowedToolNames
        )

        return AgentCoreSessionConfiguration(
            sessionID: baseConfiguration.sessionID,
            modelID: modelID,
            bearerToken: baseConfiguration.bearerToken,
            workingDirectory: baseConfiguration.workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: baseConfiguration.cacheKey,
            sessionRevision: baseConfiguration.sessionRevision + 1,
            history: baseConfiguration.history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: baseConfiguration.configuredContextWindowLimit,
            generationParameterOverrides: baseConfiguration.generationParameterOverrides,
            maxToolRounds: baseConfiguration.maxToolRounds,
            maxOutputTokens: baseConfiguration.maxOutputTokens,
            verboseLogging: baseConfiguration.verboseLogging,
            appMode: baseConfiguration.appMode,
            thinkingSelection: baseConfiguration.thinkingSelection,
            preserveThinking: baseConfiguration.preserveThinking
        )
    }

    static func acpAgentMentionLookupKeys(for agent: AgentProfile) -> Set<String> {
        Set([
            acpAgentMentionLookupKey(agent.id),
            acpAgentMentionLookupKey(agent.name),
            acpAgentMentionLookupKey(agent.displayName)
        ].filter { !$0.isEmpty })
    }

    static func acpAgentMentionLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }
}
