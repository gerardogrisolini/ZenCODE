//
//  ChatCompletionsStreamParser.swift
//  ZenCODE
//
//  Parses SSE objects from the /chat/completions streaming endpoint into
//  ParsedRemoteStreamEvent values. Extracted from RemoteGenerationClient+Streaming.
//

import Foundation

/// Parser for the `/chat/completions` streaming endpoint.
public enum ChatCompletionsStreamParser {

    /// Parses a single JSON object from the chat-completions SSE stream.
    public static func parse(
        _ object: [String: Any]
    ) -> [ParsedRemoteStreamEvent] {
        var events = RemoteGenerationClient.usageEvents(from: object)
        guard let choice = (object["choices"] as? [[String: Any]])?.first else {
            return events.isEmpty ? [.ignored] : events
        }
        if let reason = choice["finish_reason"] as? String,
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            events.append(.stop(reason))
        }
        if let delta = choice["delta"] as? [String: Any] {
            if let content = ResponsesStreamParser.streamContentText(from: delta["content"]) {
                events.append(.content(content))
            }
            let reasoning = delta["reasoning"] as? String
            let reasoningContent = delta["reasoning_content"] as? String
            if let reasoning {
                events.append(.reasoning(reasoning))
            }
            if let reasoningContent, reasoningContent != reasoning {
                events.append(.reasoning(reasoningContent))
            }
            if let rawToolCalls = delta["tool_calls"] as? [[String: Any]] {
                events.append(.toolCallDelta(rawToolCalls))
            }
        }
        if let message = choice["message"] as? [String: Any],
           let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            events.append(.toolCallDelta(rawToolCalls))
        }
        return events.isEmpty ? [.ignored] : events
    }

    /// Builds the `tools` payload array for the `/chat/completions` endpoint.
    public static func toolPayloads(
        from descriptors: [DirectToolDescriptor]
    ) -> [[String: Any]] {
        descriptors.compactMap { descriptor in
            guard let schema = descriptor.schemaObject else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": descriptor.name,
                    "description": descriptor.description,
                    "parameters": schema
                ]
            ]
        }
    }
}
