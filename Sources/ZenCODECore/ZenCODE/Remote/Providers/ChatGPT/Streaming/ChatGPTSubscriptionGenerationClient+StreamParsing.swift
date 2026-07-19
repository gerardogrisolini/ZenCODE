//
//  ChatGPTSubscriptionGenerationClient+StreamParsing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    public static func responseID(from object: [String: Any]) -> String? {
        if let response = object["response"] as? [String: Any] {
            for key in ["response_id", "responseId", "id"] {
                if let value = normalizedSessionID(response[key]) {
                    return value
                }
            }
        }

        for key in ["response_id", "responseId"] {
            if let value = normalizedSessionID(object[key]) {
                return value
            }
        }

        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        if normalizedType == "response_created"
            || normalizedType == "response_in_progress"
            || normalizedType == "response_completed"
            || normalizedType == "response_done"
            || normalizedType == "response_incomplete" {
            return normalizedSessionID(object["id"])
        }

        return nil
    }

    static func events(
        from object: [String: Any],
        modelLLMID: String
    ) -> [ChatGPTSubscriptionStreamEvent] {
        guard let type = object["type"] as? String else {
            return []
        }
        let normalizedType = normalizedEventType(type)

        switch normalizedType {
        case "thread_started",
             "session_configured":
            return []
        case "turn_started",
             "task_started":
            return []
        case "turn_completed",
             "turn_complete",
             "task_complete":
            var events: [ChatGPTSubscriptionStreamEvent] = []
            if let contextWindowStatus = contextWindowStatus(
                from: usageObject(from: object),
                modelLLMID: modelLLMID
            ) {
                events.append(.contextWindow(contextWindowStatus))
            }
            events.append(.completed(stopReason: "completed"))
            return events
        case "token_count":
            return contextWindowStatus(
                from: usageObject(from: object) ?? object,
                modelLLMID: modelLLMID
            ).map { [.contextWindow($0)] } ?? []
        case "agent_message_content_delta":
            return stringValue(for: ["delta", "text", "content"], in: object)
                .map { [.content($0)] } ?? []
        case "agent_reasoning",
             "agent_reasoning_raw_content",
             "agent_reasoning_section_break",
             "reasoning_content_delta",
             "reasoning_raw_content_delta",
             "reasoning_summary_delta",
             "reasoning_summary_part_added":
            return reasoningText(from: object)
            .map { [.thought($0)] } ?? []
        case "item_started":
            guard let item = object["item"] as? [String: Any],
                  let update = toolCallUpdate(from: item, status: "in_progress") else {
                return []
            }
            return [.toolCall(update)]
        case "item_completed":
            guard let item = object["item"] as? [String: Any] else {
                return []
            }
            return completedItemEvents(from: item)
        case "raw_response_item":
            guard let item = object["item"] as? [String: Any] else {
                return []
            }
            return completedItemEvents(from: item)
        default:
            return []
        }
    }

    static func responseErrorMessage(from object: [String: Any]) -> String? {
        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        if normalizedType == "error" {
            return errorMessage(from: object["error"])
                ?? textContent(from: object["message"])
                ?? textContent(from: object["detail"])
                ?? "ChatGPT Subscription request failed."
        }

        guard let response = object["response"] as? [String: Any] else {
            return nil
        }
        let status = (response["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedType == "response_failed" || status == "failed" else {
            return nil
        }
        return errorMessage(from: response["error"])
            ?? textContent(from: response["message"])
            ?? "ChatGPT Subscription request failed."
    }

    static func errorMessage(from value: Any?) -> String? {
        if let text = textContent(from: value) {
            return text
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        return stringValue(
            for: ["message", "detail", "code", "type"],
            in: object
        )
    }

    static func responseContentDelta(from object: [String: Any]) -> String? {
        textContent(from: object["delta"])
            ?? textContent(from: object["text"])
            ?? textContent(from: object["content"])
    }

    static func responseReasoningDelta(from object: [String: Any]) -> String? {
        reasoningText(from: object)
    }

    static func completedResponseText(from object: [String: Any]) -> String? {
        if let text = textContent(from: object["output_text"]) {
            return text
        }

        let response = object["response"] as? [String: Any] ?? object
        if let text = textContent(from: response["output_text"]) {
            return text
        }

        guard let output = response["output"] as? [Any] else {
            return nil
        }
        let text = output
            .compactMap { item -> String? in
                guard let item = item as? [String: Any] else {
                    return textContent(from: item)
                }
                if let content = item["content"] as? [Any] {
                    return content
                        .compactMap(textContent)
                        .joined(separator: "")
                        .nilIfBlank
                }
                return textContent(from: item["text"])
                    ?? textContent(from: item["content"])
            }
            .joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.nilIfBlank
    }

    static func responseUsageObject(from object: [String: Any]) -> [String: Any]? {
        usageObject(from: object)
            ?? (object["response"] as? [String: Any]).flatMap(usageObject(from:))
    }

    static func normalizedEventType(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    static func usageObject(from object: [String: Any]) -> [String: Any]? {
        for key in ["usage", "token_usage", "tokenUsage", "tokens"] {
            if let usage = object[key] as? [String: Any] {
                return usage
            }
        }
        return nil
    }

    /// Parses Codex `rate_limits` (primary/secondary windows) into a subscription usage status.
    /// The wider window maps to the weekly usage and the narrower window maps to the daily (5h) usage.
    static func subscriptionUsage(from object: [String: Any]) -> DirectAgentSubscriptionUsageStatus? {
        guard let rateLimits = rateLimitsObject(from: object) else {
            return nil
        }
        let primary = rateLimits["primary"] as? [String: Any]
        let secondary = rateLimits["secondary"] as? [String: Any]
        guard primary != nil || secondary != nil else {
            return nil
        }

        let primaryWindow = primary.flatMap { intValue(for: ["window_minutes", "windowMinutes"], in: $0) }
        let secondaryWindow = secondary.flatMap { intValue(for: ["window_minutes", "windowMinutes"], in: $0) }

        let dailyWindow: [String: Any]?
        let weeklyWindow: [String: Any]?
        if let primaryWindow, let secondaryWindow {
            if primaryWindow <= secondaryWindow {
                dailyWindow = primary
                weeklyWindow = secondary
            } else {
                dailyWindow = secondary
                weeklyWindow = primary
            }
        } else if let primaryWindow {
            // Codex can now expose only a 7d primary window. Prefer the declared
            // duration over the historical primary = 5h / secondary = weekly order.
            if isWeeklyWindow(primaryWindow) {
                dailyWindow = secondary
                weeklyWindow = primary
            } else {
                dailyWindow = primary
                weeklyWindow = secondary
            }
        } else if let secondaryWindow {
            if isWeeklyWindow(secondaryWindow) {
                dailyWindow = primary
                weeklyWindow = secondary
            } else {
                dailyWindow = secondary
                weeklyWindow = primary
            }
        } else {
            // Preserve the conventional Codex ordering for older payloads that do
            // not declare a window duration.
            dailyWindow = primary ?? secondary
            weeklyWindow = primary != nil ? secondary : nil
        }

        let dailyUsedPercent = dailyWindow.flatMap {
            doubleValue(for: ["used_percent", "usedPercent"], in: $0)
        }
        let weeklyUsedPercent = weeklyWindow.flatMap {
            doubleValue(for: ["used_percent", "usedPercent"], in: $0)
        }
        guard dailyUsedPercent != nil || weeklyUsedPercent != nil else {
            return nil
        }
        return DirectAgentSubscriptionUsageStatus(
            provider: "ChatGPT",
            dailyUsedPercent: dailyUsedPercent,
            weeklyUsedPercent: weeklyUsedPercent,
            dailyResetsInSeconds: dailyWindow.flatMap { resetsInSeconds(fromWindow: $0) },
            weeklyResetsInSeconds: weeklyWindow.flatMap { resetsInSeconds(fromWindow: $0) }
        )
    }

    private static func isWeeklyWindow(_ windowMinutes: Int) -> Bool {
        let expectedMinutes = 7 * 24 * 60
        let tolerance = expectedMinutes / 20
        let lowerBound = expectedMinutes - tolerance
        let upperBound = expectedMinutes + tolerance
        return (lowerBound...upperBound).contains(windowMinutes)
    }

    /// Resolves the seconds-until-reset for a Codex rate-limit window.
    ///
    /// Codex publishes either a relative `resets_in_seconds` value or an
    /// absolute `reset_at` Unix timestamp (used by the `codex.rate_limits`
    /// streaming event). When only the absolute timestamp is available, it is
    /// converted to a relative offset from `now`.
    static func resetsInSeconds(
        fromWindow window: [String: Any],
        now: Date = Date()
    ) -> Int? {
        if let relative = intValue(for: ["resets_in_seconds", "resetsInSeconds"], in: window) {
            return relative
        }
        guard let resetAt = doubleValue(for: ["reset_at", "resetAt", "resets_at", "resetsAt"], in: window) else {
            return nil
        }
        let remaining = resetAt - now.timeIntervalSince1970
        guard remaining.isFinite, remaining > 0 else {
            return nil
        }
        return Int(remaining.rounded())
    }

    /// Parses subscription usage from the Codex `x-codex-*` response headers,
    /// reusing the shared `rate_limits` parsing path.
    static func subscriptionUsage(
        fromHTTPResponse response: URLResponse
    ) -> DirectAgentSubscriptionUsageStatus? {
        guard let rateLimits = rateLimitsObject(fromHTTPResponse: response) else {
            return nil
        }
        return subscriptionUsage(from: ["rate_limits": rateLimits])
    }

    /// Builds a `rate_limits` object (`primary`/`secondary` windows) from the
    /// Codex `x-codex-*` response headers so it can flow through the same
    /// parsing path used for the inline `codex.rate_limits` streaming event.
    static func rateLimitsObject(
        fromHTTPResponse response: URLResponse
    ) -> [String: Any]? {
        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        let primary = rateLimitWindow(
            in: httpResponse,
            usedPercentKey: "x-codex-primary-used-percent",
            windowMinutesKey: "x-codex-primary-window-minutes",
            resetAtKey: "x-codex-primary-reset-at"
        )
        let secondary = rateLimitWindow(
            in: httpResponse,
            usedPercentKey: "x-codex-secondary-used-percent",
            windowMinutesKey: "x-codex-secondary-window-minutes",
            resetAtKey: "x-codex-secondary-reset-at"
        )
        guard primary != nil || secondary != nil else {
            return nil
        }

        var rateLimits: [String: Any] = [:]
        if let primary {
            rateLimits["primary"] = primary
        }
        if let secondary {
            rateLimits["secondary"] = secondary
        }
        return rateLimits
    }

    private static func rateLimitWindow(
        in response: HTTPURLResponse,
        usedPercentKey: String,
        windowMinutesKey: String,
        resetAtKey: String
    ) -> [String: Any]? {
        guard let usedPercent = headerDouble(in: response, keys: [usedPercentKey]) else {
            return nil
        }
        var window: [String: Any] = ["used_percent": usedPercent]
        if let windowMinutes = headerInt(in: response, keys: [windowMinutesKey]) {
            window["window_minutes"] = windowMinutes
        }
        if let resetAt = headerDouble(in: response, keys: [resetAtKey]) {
            window["reset_at"] = resetAt
        }
        return window
    }

    private static func headerDouble(
        in response: HTTPURLResponse,
        keys: [String]
    ) -> Double? {
        for key in keys {
            guard let raw = response.value(forHTTPHeaderField: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            let normalized = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
            if let value = Double(normalized.trimmingCharacters(in: .whitespacesAndNewlines)),
               value.isFinite {
                return value
            }
        }
        return nil
    }

    private static func headerInt(
        in response: HTTPURLResponse,
        keys: [String]
    ) -> Int? {
        for key in keys {
            guard let raw = response.value(forHTTPHeaderField: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            if let value = Int(raw) {
                return value
            }
            if let value = Double(raw) {
                return Int(value.rounded())
            }
        }
        return nil
    }

    static func rateLimitsObject(from object: [String: Any]) -> [String: Any]? {
        for key in ["rate_limits", "rateLimits"] {
            if let value = object[key] as? [String: Any] {
                return value
            }
        }
        if let response = object["response"] as? [String: Any] {
            for key in ["rate_limits", "rateLimits"] {
                if let value = response[key] as? [String: Any] {
                    return value
                }
            }
        }
        return nil
    }

    static func doubleValue(
        for keys: [String],
        in object: [String: Any]
    ) -> Double? {
        for key in keys {
            if let value = JSONValue(jsonObject: object[key]).doubleValue {
                return value
            }
        }
        return nil
    }

    static func reasoningText(from object: [String: Any]) -> String? {
        stringValue(
            for: [
                "delta",
                "text",
                "summary_text",
                "summaryText",
                "raw_content",
                "rawContent",
                "reasoning_text",
                "reasoningText",
                "content",
                "summary"
            ],
            in: object
        )
        ?? (object["item"] as? [String: Any]).flatMap {
            stringValue(
                for: [
                    "delta",
                    "text",
                    "summary_text",
                    "summaryText",
                    "raw_content",
                    "rawContent",
                    "reasoning_text",
                    "reasoningText",
                    "content",
                    "summary"
                ],
                in: $0
            )
        }
    }

    static func completedItemEvents(from item: [String: Any]) -> [ChatGPTSubscriptionStreamEvent] {
        let itemType = (item["type"] as? String ?? "").lowercased()
        let text = stringValue(
            for: [
                "text",
                "content",
                "summary",
                "summary_text",
                "summaryText",
                "raw_content",
                "rawContent",
                "reasoning_text",
                "reasoningText"
            ],
            in: item
        )

        if itemType == "agent_message" || itemType == "message" {
            return text.map { [.content($0)] } ?? []
        }
        if itemType.contains("reasoning") || itemType.contains("thought") {
            return text.map { [.thought($0)] } ?? []
        }
        if let update = toolCallUpdate(from: item, status: "completed") {
            return [.toolCall(update)]
        }
        return []
    }

    static func toolCallUpdate(
        from item: [String: Any],
        status: String
    ) -> ChatGPTSubscriptionToolCallUpdate? {
        let itemType = (item["type"] as? String ?? "").lowercased()
        guard itemType != "agent_message",
              itemType != "message",
              !itemType.contains("reasoning"),
              !itemType.contains("thought") else {
            return nil
        }

        let id = (item["id"] as? String)?.nilIfBlank ?? UUID().uuidString
        let title = stringValue(for: ["title", "name", "command"], in: item)
            ?? displayTitle(forItemType: itemType)
        let rawInput = compactJSONString(from: item["input"] ?? item["arguments"] ?? item)
        let output = stringValue(for: ["output", "result", "text", "content"], in: item)
        return ChatGPTSubscriptionToolCallUpdate(
            id: id,
            title: title,
            status: status,
            rawInput: rawInput,
            output: output
        )
    }

    static func directToolCall(
        from update: ChatGPTSubscriptionToolCallUpdate
    ) -> DirectAgentToolCall {
        let argumentsObject = argumentsObject(from: update.rawInput)
        return DirectAgentToolCall(
            id: update.id,
            name: update.title,
            argumentsObject: argumentsObject,
            argumentsJSON: update.rawInput ?? "{}"
        )
    }

    static func argumentsObject(from rawInput: String?) -> [String: Any] {
        guard let rawInput = rawInput?.nilIfBlank,
              let data = rawInput.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            return [:]
        }
        return object.mapValues(\.jsonObject)
    }

    static func contextWindowStatus(
        from usage: [String: Any]?,
        modelLLMID: String
    ) -> DirectAgentContextWindowStatus? {
        guard let usage else {
            return nil
        }
        let inputTokens = boundedCodexTokenCount(
            totalInputTokenCount(from: usage),
            modelLLMID: modelLLMID
        )
        guard let inputTokens,
              let maxTokens = CodexAgentModel.contextWindowTokenLimit(forLLMID: modelLLMID) else {
            return nil
        }

        return DirectAgentContextWindowStatus(
            usedTokens: inputTokens,
            maxTokens: maxTokens,
            modelID: modelLLMID,
            isApproximate: true
        )
    }

    static func totalInputTokenCount(from usage: [String: Any]) -> Int? {
        if let totalInputTokens = intValue(
            for: ["prompt_tokens", "total_input_tokens", "promptTokens", "totalInputTokens"],
            in: usage
        ) {
            return totalInputTokens
        }

        let inputTokens = intValue(
            for: ["input_tokens", "inputTokens"],
            in: usage
        )
        let cacheReadInputTokens = intValue(
            for: ["cache_read_input_tokens", "cacheReadInputTokens"],
            in: usage
        )
        let cacheCreationInputTokens = intValue(
            for: ["cache_creation_input_tokens", "cacheCreationInputTokens"],
            in: usage
        )

        if cacheReadInputTokens != nil || cacheCreationInputTokens != nil,
           let inputTokens {
            return inputTokens
                + (cacheReadInputTokens ?? 0)
                + (cacheCreationInputTokens ?? 0)
        }
        return inputTokens
    }

    static func boundedCodexTokenCount(
        _ value: Int?,
        modelLLMID: String
    ) -> Int? {
        guard let value, value >= 0 else {
            return nil
        }
        guard let maxTokens = CodexAgentModel.contextWindowTokenLimit(forLLMID: modelLLMID),
              value <= maxTokens else {
            return nil
        }
        return value
    }

    static func stringValue(
        for keys: [String],
        in object: [String: Any]
    ) -> String? {
        for key in keys {
            if let normalizedValue = textContent(from: object[key]) {
                return normalizedValue
            }
        }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        textContent(from: value)
    }

    static func textContent(from value: Any?) -> String? {
        if let value = value as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : value
        }
        if let values = value as? [Any] {
            let text = values
                .compactMap(textContent)
                .joined(separator: "\n")
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedText.isEmpty ? nil : text
        }
        if let object = value as? [String: Any] {
            return stringValue(
                for: [
                    "text",
                    "summary_text",
                    "raw_content",
                    "reasoning_text",
                    "content",
                    "delta",
                    "summary"
                ],
                in: object
            )
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        JSONValue(jsonObject: value).intValue
    }

    /// True when a reasoning output item carries state that can be replayed on a
    /// later request while `store` is disabled.
    static func reasoningItemHasReplayableContent(_ item: [String: Any]) -> Bool {
        RemoteGenerationClient.responseReasoningItemHasReplayableContent(item)
    }

    /// Keeps only the fields the Responses API accepts when a reasoning item is
    /// replayed as input, dropping streaming-only metadata.
    static func sanitizedReasoningItem(_ item: [String: Any]) -> [String: Any] {
        RemoteGenerationClient.sanitizedResponseReasoningItem(item)
    }

    static func intValue(
        for keys: [String],
        in object: [String: Any]
    ) -> Int? {
        for key in keys {
            if let value = intValue(object[key]) {
                return value
            }
        }
        return nil
    }

    static func compactJSONString(from value: Any?) -> String? {
        guard let value else {
            return nil
        }
        return JSONValue(jsonObject: value).compactString(sortedKeys: true)
    }

    static func displayTitle(forItemType itemType: String) -> String {
        if itemType.isEmpty {
            return "ChatGPT action"
        }
        return itemType
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
