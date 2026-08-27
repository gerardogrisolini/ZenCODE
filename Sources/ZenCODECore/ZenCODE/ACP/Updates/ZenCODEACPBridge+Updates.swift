//
//  ZenCODEACPBridge+Updates.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension ZenCODEACPBridge {
    public func sendUserMessageChunk(sessionID: String, text: String) async {
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: Self.textChunkJSONUpdate(kind: "user_message_chunk", text: text)
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

    public static func toolCallCreateUpdate(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL? = nil
    ) -> [String: Any] {
        [
            "sessionUpdate": "tool_call",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall, workingDirectory: workingDirectory),
            "status": "pending",
            "content": [] as [Any],
            "locations": toolLocations(for: toolCall, workingDirectory: workingDirectory),
            "_meta": [
                "rawInput": toolCall.argumentsObject
            ]
        ]
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
    public static func subscriptionUsageData(
        for status: DirectAgentSubscriptionUsageStatus
    ) -> [String: Any]? {
        guard status.hasValues else {
            return nil
        }
        var data: [String: Any] = ["provider": status.provider]
        if let dailyUsedPercent = status.dailyUsedPercent {
            data["dailyUsedPercent"] = dailyUsedPercent
        }
        if let weeklyUsedPercent = status.weeklyUsedPercent {
            data["weeklyUsedPercent"] = weeklyUsedPercent
        }
        if let dailyResetsInSeconds = status.dailyResetsInSeconds {
            data["dailyResetsInSeconds"] = dailyResetsInSeconds
        }
        if let weeklyResetsInSeconds = status.weeklyResetsInSeconds {
            data["weeklyResetsInSeconds"] = weeklyResetsInSeconds
        }
        return data
    }

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

    public static func toolCallProgressUpdate(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL? = nil
    ) -> [String: Any] {
        [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall, workingDirectory: workingDirectory),
            "status": "in_progress",
            "locations": toolLocations(for: toolCall, workingDirectory: workingDirectory),
            "_meta": [
                "rawInput": toolCall.argumentsObject
            ]
        ]
    }

    public static func toolCallProgressJSONUpdate(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL? = nil
    ) -> JSONValue {
        JSONValue.acpValue(from: toolCallProgressUpdate(for: toolCall, workingDirectory: workingDirectory))
    }

    public static func toolCallCompletionUpdate(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        workingDirectory: URL? = nil
    ) -> [String: Any] {
        var update: [String: Any] = [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall, workingDirectory: workingDirectory),
            "status": result.isFailure ? "failed" : "completed",
            "locations": toolLocations(for: toolCall, workingDirectory: workingDirectory),
            "_meta": [
                "rawInput": toolCall.argumentsObject,
                "rawOutput": [
                    "output": result.output,
                    "summary": result.summary
                ]
            ]
        ]
        if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            update["content"] = [
                [
                    "type": "content",
                    "content": [
                        "type": "text",
                        "text": result.output
                    ]
                ]
            ]
        }
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

    static func textChunkJSONUpdate(kind: String, text: String) -> JSONValue {
        .object([
            "sessionUpdate": .string(kind),
            "content": .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        ])
    }


    // Kept as forwarding APIs for ACP clients that previously used these helpers.
    public static func toolTitle(for toolCall: DirectAgentToolCall) -> String {
        ToolCallPresentation.toolTitle(for: toolCall)
    }

    public static func toolKind(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL? = nil
    ) -> String {
        acpToolKind(
            ToolCallPresentation.toolKind(for: toolCall),
            hasFileLocations: !toolLocations(
                for: toolCall,
                workingDirectory: workingDirectory
            ).isEmpty
        )
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

    public static func toolIcon(for toolName: String) -> String {
        ToolCallPresentation.toolIcon(for: toolName)
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

    public static func displayToolTarget(for toolCall: DirectAgentToolCall) -> String? {
        ToolCallPresentation.displayToolTarget(for: toolCall)
    }

    public static func patchDisplayTarget(from arguments: [String: Any]) -> String? {
        ToolCallPresentation.patchDisplayTarget(from: arguments)
    }

    public static func compactJSONString(from value: Any) -> String? {
        JSONValue(jsonObject: value).compactString(sortedKeys: true)
    }

    public static func isAppSuppressedDiagnostic(_ message: String) -> Bool {
        isMetricsDiagnostic(message)
            || message.hasPrefix("Remote request:")
    }

    public static func isMetricsDiagnostic(_ message: String) -> Bool {
        message.hasPrefix("Generation done:")
    }
}
