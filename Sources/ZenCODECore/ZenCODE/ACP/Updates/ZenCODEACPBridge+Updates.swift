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
            update: .object([
                "sessionUpdate": .string("user_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ])
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
        for toolCall: DirectAgentToolCall
    ) -> [String: Any] {
        [
            "sessionUpdate": "tool_call",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall),
            "status": "pending",
            "rawInput": toolCall.argumentsObject,
            "content": [] as [Any],
            "locations": toolLocations(for: toolCall)
        ]
    }

    /// Sendable ACP wire representation used by prompt event callbacks.
    public static func toolCallCreateJSONUpdate(
        for toolCall: DirectAgentToolCall
    ) -> JSONValue {
        .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string(toolCall.id),
            "title": .string(toolTitle(for: toolCall)),
            "kind": .string(toolKind(for: toolCall)),
            "status": .string("pending"),
            "rawInput": toolArgumentsJSONValue(for: toolCall),
            "content": .array([]),
            "locations": .array(toolLocations(for: toolCall).map { JSONValue.acpValue(from: $0) })
        ])
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
        guard let usedTokens = status.usedTokens,
              let maxTokens = status.maxTokens else {
            return nil
        }
        let used = max(0, usedTokens)
        let size = max(used, maxTokens)
        return .object([
            "sessionUpdate": .string("usage_update"),
            "used": .number(Double(used)),
            "size": .number(Double(size)),
            "_meta": .object([
                "modelID": .string(status.modelID),
                "isApproximate": .bool(status.isApproximate)
            ])
        ])
    }

    public static func subscriptionUsageUpdate(
        for status: DirectAgentSubscriptionUsageStatus
    ) -> [String: Any]? {
        guard status.hasValues else {
            return nil
        }
        var meta: [String: Any] = ["provider": status.provider]
        if let dailyUsedPercent = status.dailyUsedPercent {
            meta["dailyUsedPercent"] = dailyUsedPercent
        }
        if let weeklyUsedPercent = status.weeklyUsedPercent {
            meta["weeklyUsedPercent"] = weeklyUsedPercent
        }
        if let dailyResetsInSeconds = status.dailyResetsInSeconds {
            meta["dailyResetsInSeconds"] = dailyResetsInSeconds
        }
        if let weeklyResetsInSeconds = status.weeklyResetsInSeconds {
            meta["weeklyResetsInSeconds"] = weeklyResetsInSeconds
        }
        return [
            "sessionUpdate": "subscription_usage_update",
            "_meta": meta
        ]
    }

    public static func subscriptionUsageJSONUpdate(
        for status: DirectAgentSubscriptionUsageStatus
    ) -> JSONValue? {
        guard status.hasValues else {
            return nil
        }
        var meta: [String: JSONValue] = ["provider": .string(status.provider)]
        if let dailyUsedPercent = status.dailyUsedPercent, dailyUsedPercent.isFinite {
            meta["dailyUsedPercent"] = .number(dailyUsedPercent)
        }
        if let weeklyUsedPercent = status.weeklyUsedPercent, weeklyUsedPercent.isFinite {
            meta["weeklyUsedPercent"] = .number(weeklyUsedPercent)
        }
        if let dailyResetsInSeconds = status.dailyResetsInSeconds {
            meta["dailyResetsInSeconds"] = .number(Double(dailyResetsInSeconds))
        }
        if let weeklyResetsInSeconds = status.weeklyResetsInSeconds {
            meta["weeklyResetsInSeconds"] = .number(Double(weeklyResetsInSeconds))
        }
        return .object([
            "sessionUpdate": .string("subscription_usage_update"),
            "_meta": .object(meta)
        ])
    }

    public static func toolCallProgressUpdate(
        for toolCall: DirectAgentToolCall
    ) -> [String: Any] {
        [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall),
            "status": "in_progress",
            "rawInput": toolCall.argumentsObject,
            "locations": toolLocations(for: toolCall)
        ]
    }

    public static func toolCallProgressJSONUpdate(
        for toolCall: DirectAgentToolCall
    ) -> JSONValue {
        .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string(toolCall.id),
            "title": .string(toolTitle(for: toolCall)),
            "kind": .string(toolKind(for: toolCall)),
            "status": .string("in_progress"),
            "rawInput": toolArgumentsJSONValue(for: toolCall),
            "locations": .array(toolLocations(for: toolCall).map { JSONValue.acpValue(from: $0) })
        ])
    }

    public static func toolCallCompletionUpdate(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> [String: Any] {
        return [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall),
            "status": result.isFailure ? "failed" : "completed",
            "rawInput": toolCall.argumentsObject,
            "rawOutput": [
                "output": result.output,
                "summary": result.summary
            ],
            "content": [
                [
                    "type": "content",
                    "content": [
                        "type": "text",
                        "text": result.output
                    ]
                ]
            ],
            "locations": toolLocations(for: toolCall)
        ]
    }

    public static func toolCallCompletionJSONUpdate(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> JSONValue {
        .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string(toolCall.id),
            "title": .string(toolTitle(for: toolCall)),
            "kind": .string(toolKind(for: toolCall)),
            "status": .string(result.isFailure ? "failed" : "completed"),
            "rawInput": toolArgumentsJSONValue(for: toolCall),
            "rawOutput": .object([
                "output": .string(result.output),
                "summary": .string(result.summary)
            ]),
            "content": .array([
                .object([
                    "type": .string("content"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(result.output)
                    ])
                ])
            ]),
            "locations": .array(toolLocations(for: toolCall).map { JSONValue.acpValue(from: $0) })
        ])
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

    private static func toolArgumentsJSONValue(
        for toolCall: DirectAgentToolCall
    ) -> JSONValue {
        guard let data = toolCall.argumentsJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let arguments = value.objectValue else {
            return .object([:])
        }
        return .object(arguments)
    }

    // Kept as forwarding APIs for ACP clients that previously used these helpers.
    public static func toolTitle(for toolCall: DirectAgentToolCall) -> String {
        ToolCallPresentation.toolTitle(for: toolCall)
    }

    public static func toolKind(for toolCall: DirectAgentToolCall) -> String {
        ToolCallPresentation.toolKind(for: toolCall)
    }

    public static func xcodeToolKind(for rawName: String) -> String {
        ToolCallPresentation.xcodeToolKind(for: rawName)
    }

    public static func toolIcon(for toolName: String) -> String {
        ToolCallPresentation.toolIcon(for: toolName)
    }

    public static func toolLocations(for toolCall: DirectAgentToolCall) -> [[String: Any]] {
        ToolCallPresentation.toolLocations(for: toolCall)
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
