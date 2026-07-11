//
//  ZenCODEACPBridge+Updates.swift
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
    public func sendUserMessageChunk(sessionID: String, text: String) async {
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: JSONValue.acpValue(from: [
                "sessionUpdate": "user_message_chunk",
                "content": [
                    "type": "text",
                    "text": text
                ]
            ])
        )
    }

    public func sendSessionInfoUpdate(sessionID: String, title: String) async {
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: JSONValue.acpValue(from: [
                "sessionUpdate": "session_info_update",
                "title": title,
                "updatedAt": ISO8601DateFormatter().string(from: Date())
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
            "kind": toolKind(for: toolCall.name),
            "status": "pending",
            "rawInput": toolCall.argumentsObject,
            "content": [] as [Any],
            "locations": toolLocations(for: toolCall)
        ]
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

    public static func toolCallProgressUpdate(
        for toolCall: DirectAgentToolCall
    ) -> [String: Any] {
        [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall.name),
            "status": "in_progress",
            "rawInput": toolCall.argumentsObject,
            "locations": toolLocations(for: toolCall)
        ]
    }

    public static func toolCallCompletionUpdate(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> [String: Any] {
        return [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall.name),
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

    // Kept as forwarding APIs for ACP clients that previously used these helpers.
    public static func toolTitle(for toolCall: DirectAgentToolCall) -> String {
        ToolCallPresentation.toolTitle(for: toolCall)
    }

    public static func toolKind(for toolName: String) -> String {
        ToolCallPresentation.toolKind(for: toolName)
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
