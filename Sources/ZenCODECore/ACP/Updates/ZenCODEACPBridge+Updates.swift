//
//  ZenCODEACPBridge+Updates.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension ZenCODEACPBridge {
    /// A message of the user, as `session/load` replays it. A `session/prompt`
    /// never echoes the prompt: the client shows the message it sent. As
    /// every chunk, it names its message (`messageId`).
    public func sendUserMessageChunk(sessionID: String, text: String, messageID: String) async {
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: Self.textChunkJSONUpdate(kind: "user_message_chunk", text: text, messageID: messageID)
        )
    }

    public func sendSessionInfoUpdate(sessionID: String, title: String) async {
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: .object([
                "sessionUpdate": .string("session_info_update"),
                "title": .string(title),
                "updatedAt": .string(ISO8601DateFormatter().string(from: Date()))
            ])
        )
    }

    public func promptTitle(from prompt: String) -> String {
        Self.sessionTitle(fromPrompt: prompt)
    }

    /// The title a prompt gives its session: its first line, at most 80
    /// characters.
    static func sessionTitle(fromPrompt prompt: String) -> String {
        let firstLine = prompt
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "ZenCODE session"
        if firstLine.count <= 80 {
            return firstLine
        }
        return "\(firstLine.prefix(77))..."
    }

    /// Gives the live incarnation `epoch` of `sessionID` the title of `prompt`
    /// and tells the client, unless the session already has a title.
    ///
    /// The title is born once, from the first prompt of the conversation, as
    /// in codex-acp: later prompts never change it, and a session that was
    /// restored with a title (see ``restoredSessionTitle(savedName:history:displayTexts:)``)
    /// keeps it. There is no placeholder title: until a prompt (or a restore)
    /// names the session, nothing is sent. The title is claimed in one
    /// synchronous step on the entry, so at most one `session_info_update` is
    /// written for a title.
    func presentSessionTitleIfNeeded(
        fromPrompt prompt: String,
        sessionID: String,
        epoch: UInt64
    ) async {
        let title = Self.sessionTitle(fromPrompt: prompt)
        guard title.nilIfBlank != nil else { return }
        var didClaim = false
        updateLiveSession(id: sessionID, epoch: epoch) { live in
            guard live.sessionTitle == nil else { return }
            live.sessionTitle = title
            didClaim = true
        }
        guard didClaim else { return }
        await sendSessionInfoUpdate(sessionID: sessionID, title: title)
    }

    /// The `tool_call` that announces a call.
    ///
    /// Everything the client needs to render the call is a standard ACP v1
    /// field, because clients read `_meta` for nothing: the readable `title`
    /// (``toolTitle(for:)``), the programmatic `name`, the `kind`, the
    /// `locations`, and the tool arguments as `rawInput`. The title is fixed
    /// here and the completion never repeats it; `rawInput` is sent once and
    /// the completion does not repeat it either.
    public static func toolCallCreateUpdate(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL? = nil
    ) -> [String: Any] {
        var update = toolCallCommonFields(for: toolCall, workingDirectory: workingDirectory)
        update["sessionUpdate"] = "tool_call"
        update["title"] = toolTitle(for: toolCall)
        update["name"] = toolCall.name
        update["rawInput"] = toolCall.argumentsObject
        update["status"] = "pending"
        update["content"] = [] as [Any]
        return update
    }

    /// Sendable ACP wire representation used by prompt event callbacks.
    public static func toolCallCreateJSONUpdate(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL? = nil
    ) -> JSONValue {
        JSONValue.acpValue(from: toolCallCreateUpdate(for: toolCall, workingDirectory: workingDirectory))
    }

    public static func usageUpdate(
        for status: DirectAgentContextWindowStatus
    ) -> [String: Any]? {
        guard let usedTokens = status.usedTokens,
              let maxTokens = status.maxTokens else {
            return nil
        }
        let used = max(0, usedTokens)
        let size = max(used, maxTokens)
        let update: [String: Any] = [
            "sessionUpdate": "usage_update",
            "used": used,
            "size": size,
            "_meta": [
                "modelID": status.modelID,
                "isApproximate": status.isApproximate
            ]
        ]
        return update
    }

    public static func usageJSONUpdate(
        for status: DirectAgentContextWindowStatus
    ) -> JSONValue? {
        usageUpdate(for: status).map(JSONValue.acpValue(from:))
    }

    /// Subscription telemetry data for the custom `_zencode/usage/subscription`
    /// notification. Unlike token context-window updates, subscription usage is
    /// not a schema-valid ACP `usage_update` (it has no `used`/`size` fields), so
    /// it is sent as a namespaced custom notification that is not routed through
    /// the prompt update buffer. The prompt path enqueues a buffer flush ahead of
    /// the notification in the same serialized pipeline, so the bypass cannot
    /// reorder the notification ahead of content the turn already produced.
    public static func subscriptionUsageJSONData(
        for status: DirectAgentSubscriptionUsageStatus
    ) -> JSONValue? {
        guard status.hasValues else {
            return nil
        }
        var data: [String: JSONValue] = ["provider": .string(status.provider)]
        if let dailyUsedPercent = status.dailyUsedPercent, dailyUsedPercent.isFinite {
            data["dailyUsedPercent"] = .number(dailyUsedPercent)
        }
        if let weeklyUsedPercent = status.weeklyUsedPercent, weeklyUsedPercent.isFinite {
            data["weeklyUsedPercent"] = .number(weeklyUsedPercent)
        }
        if let dailyResetsInSeconds = status.dailyResetsInSeconds {
            data["dailyResetsInSeconds"] = .number(Double(dailyResetsInSeconds))
        }
        if let weeklyResetsInSeconds = status.weeklyResetsInSeconds {
            data["weeklyResetsInSeconds"] = .number(Double(weeklyResetsInSeconds))
        }
        return .object(data)
    }

    /// The `tool_call_update` that completes a call.
    ///
    /// It carries only what the completion adds: the final `status` and the
    /// result as `content` (visible text and diffs), once. It has no `title`
    /// (the one of the `tool_call` stays, so a client never replaces a command
    /// label with a decorated one), no `rawInput` (already on the `tool_call`),
    /// and no `rawOutput` or `_meta` copy of the result: `content` is the
    /// result, as in codex-acp ("a command sends its output once").
    public static func toolCallCompletionUpdate(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        workingDirectory: URL? = nil
    ) -> [String: Any] {
        var update = toolCallCommonFields(for: toolCall, workingDirectory: workingDirectory)
        update["sessionUpdate"] = "tool_call_update"
        update["status"] = result.isFailure ? "failed" : "completed"
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: result.fileChanges,
            workingDirectory: workingDirectory
        )
        let resultLocations = artifacts.map { ["path": $0.absolutePath] }
        if !resultLocations.isEmpty {
            // The tool arguments describe the requested operation, but the
            // recorder is authoritative about every file actually changed.
            // Publish those exact paths on completion so clients that build
            // their artifact list from `locations` do not collapse a
            // multi-file operation to its command/workspace target.
            update["locations"] = resultLocations
        }
        let visibleText = result.fileChanges.isEmpty ? result.output : [result.summary, result.output]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .reduce(into: [String]()) { texts, text in
                if !texts.contains(text) { texts.append(text) }
            }.joined(separator: "\n\n")
        var content = [[String: Any]]()
        if !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(toolCallTextContent(visibleText))
        }
        for artifact in artifacts {
            if let explanation = artifact.explanation {
                content.append(toolCallTextContent("\(artifact.absolutePath): \(explanation)"))
            } else if let patch = artifact.patch {
                // ACP diff content requires complete old/new images. A compact
                // patch is standard text content, never a fabricated empty file.
                content.append(toolCallTextContent("\(artifact.absolutePath):\n\(patch)"))
            } else {
                content.append([
                    "type": "diff", "path": artifact.absolutePath,
                    "oldText": artifact.oldText as Any? ?? NSNull(),
                    "newText": artifact.newText ?? ""
                ])
            }
        }
        if !content.isEmpty { update["content"] = content }
        return update
    }

    public static func toolCallCompletionJSONUpdate(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        workingDirectory: URL? = nil
    ) -> JSONValue {
        JSONValue.acpValue(from: toolCallCompletionUpdate(
            for: toolCall,
            result: result,
            workingDirectory: workingDirectory
        ))
    }

    /// The fields `tool_call` and `tool_call_update` share: the id, the ACP
    /// kind, and the locations the arguments point at.
    private static func toolCallCommonFields(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL?
    ) -> [String: Any] {
        let locations = toolLocations(for: toolCall, workingDirectory: workingDirectory)
        return [
            "toolCallId": toolCall.id,
            "kind": acpToolKind(
                ToolCallPresentation.toolKind(for: toolCall),
                hasFileLocations: !locations.isEmpty
            ),
            "locations": locations
        ]
    }

    private static func toolCallTextContent(_ text: String) -> [String: Any] {
        [
            "type": "content",
            "content": [
                "type": "text",
                "text": text,
            ],
        ]
    }

    /// A `user_message_chunk`, `agent_message_chunk`, or `agent_thought_chunk`
    /// of text.
    ///
    /// `messageID` is the standard ACP `messageId`: every chunk of one message
    /// shares it, and a change of it tells the client a new message started.
    /// A chunk of a streamed message is written without one: the turn's update
    /// pipeline (``ACPPromptUpdatePipeline``), which sees the whole stream in
    /// order, gives it the id of the message it belongs to. Any other message
    /// is one chunk with an id of its own (``newMessageID()``).
    static func textChunkJSONUpdate(kind: String, text: String, messageID: String? = nil) -> JSONValue {
        var update: [String: JSONValue] = [
            "sessionUpdate": .string(kind),
            "content": .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        ]
        if let messageID {
            update["messageId"] = .string(messageID)
        }
        return .object(update)
    }

    /// The id of a new message of the live conversation: unique, so no two
    /// messages of a session (or of two turns) ever share it.
    static func newMessageID() -> String {
        UUID().uuidString.lowercased()
    }

    /// The id of the message of the history entry `index` of the session
    /// `sessionID`, as `session/load` replays it: the same for every replay of
    /// the same history, and never one of a live message (``newMessageID()``).
    static func replayMessageID(sessionID: String, index: Int) -> String {
        "\(sessionID)#replay-\(index)"
    }


    /// The ACP `title` of a tool call: readable, set once on the `tool_call`
    /// and never changed by the completion.
    ///
    /// - A call of kind `execute` (today `local.exec`) is titled with the bare
    ///   command, without the tool name: clients such as Zed and Xcode use the
    ///   title as the command label (`git diff --check HEAD`).
    /// - A call with a presentation is titled `<action> <target>` from its
    ///   compact presentation (`Read Sources/App.swift`, `Search needle`).
    ///   The target keeps the safe fallbacks of the compact presentation; with
    ///   no target at all the action stands alone, and with no action the title
    ///   is the one of a call without presentation.
    /// - A call without a presentation (MCP tools such as `xcode-tools.*`) is
    ///   titled `<tool.name> <target>`, or the name alone when no safe
    ///   argument target exists.
    ///
    /// Specific to ACP: ``ToolCallPresentation/toolTitle(for:)``, shared by
    /// the other consumers, is unchanged.
    public static func toolTitle(for toolCall: DirectAgentToolCall) -> String {
        guard toolCall.presentation != nil else {
            return ToolCallPresentation.toolTitle(for: toolCall)
        }
        let target = ToolCallPresentation.displayToolTarget(for: toolCall)
        let presentation = ToolCallPresentation.resolved(for: toolCall, mode: .compact)
        if presentation.kind == .execute {
            return target ?? toolCall.name
        }
        guard let action = presentation.action?.nilIfBlank else {
            return ToolCallPresentation.toolTitle(for: toolCall)
        }
        guard let target else {
            return action
        }
        return "\(action) \(target)"
    }

    /// ACP v1 defines a closed tool-kind set: `read`, `edit`, `delete`, `move`,
    /// `search`, `execute`, `think`, `fetch`, `switch_mode`, and `other`. The
    /// internal presentation taxonomy is richer, so every value without a
    /// protocol counterpart is mapped onto the nearest valid kind: a client that
    /// decodes `kind` into that closed set cannot render an unknown value, and
    /// the tool call degrades to an unlabeled row.
    public static func acpToolKind(
        _ presentationKind: String,
        hasFileLocations: Bool = false
    ) -> String {
        switch presentationKind {
        case "read", "edit", "delete", "move", "search", "execute", "think", "fetch", "switch_mode":
            return presentationKind
        case "inspect":
            // Inspecting a file or a resource reads it without mutating it.
            return "read"
        case "create":
            // Creating a filesystem entry is a file mutation, while creating a
            // task or a sub-agent is not and must stay generic.
            return hasFileLocations ? "edit" : "other"
        case "destructive":
            // Permission requests use this internal kind for irreversible
            // operations; `delete` is the only protocol kind that conveys it.
            return "delete"
        default:
            return "other"
        }
    }

    public static func toolLocations(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL? = nil
    ) -> [[String: Any]] {
        ToolCallPresentation.toolLocations(
            for: toolCall,
            workingDirectory: workingDirectory
        )
    }
}
