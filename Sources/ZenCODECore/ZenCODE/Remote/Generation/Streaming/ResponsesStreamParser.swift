//
//  ResponsesStreamParser.swift
//  ZenCODE
//
//  Parses SSE objects from the /responses streaming endpoint into
//  ParsedRemoteStreamEvent values. Extracted from RemoteGenerationClient+Streaming.
//

import Foundation

/// Parser for the `/responses` streaming endpoint.
public enum ResponsesStreamParser {

    /// Parses a single JSON object from the responses SSE stream.
    public static func parse(
        _ object: [String: Any]
    ) -> [ParsedRemoteStreamEvent] {
        var usageEvents = RemoteGenerationClient.usageEvents(from: object)
        if let error = object["error"],
           let message = RemoteStreamTransport.responseErrorMessage(from: error)?.nilIfBlank {
            usageEvents.append(.failure(message))
            return usageEvents
        }
        guard let type = object["type"] as? String else {
            return usageEvents.isEmpty ? [.ignored] : usageEvents
        }
        switch type {
        case "error":
            usageEvents.append(
                .failure(
                    RemoteStreamTransport.responseFailureMessage(
                        from: object,
                        fallbackType: type
                    )
                )
            )
            return usageEvents
        case "response.output_text.delta":
            usageEvents.append(.content(object["delta"] as? String ?? ""))
            return usageEvents
        case "response.output_text.done":
            if let text = streamContentText(from: object["text"] ?? object["delta"] ?? object["content"]),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                usageEvents.append(.contentSnapshot(text))
            }
            return usageEvents
        case "response.refusal.delta":
            usageEvents.append(.content(object["delta"] as? String ?? ""))
            return usageEvents
        case "response.refusal.done":
            if let refusal = streamContentText(from: object["refusal"] ?? object["text"]),
               !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                usageEvents.append(.contentSnapshot(refusal))
            }
            usageEvents.append(.stop("refusal"))
            return usageEvents
        case "response.content_part.delta":
            if let delta = responseContentPartDelta(from: object) {
                usageEvents.append(.content(delta))
            }
            return usageEvents
        case "response.content_part.done":
            if let part = object["part"] as? [String: Any],
               let text = responseContentPartText(from: part) {
                usageEvents.append(.contentSnapshot(text))
            }
            return usageEvents
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            usageEvents.append(.reasoning(object["delta"] as? String ?? ""))
            return usageEvents
        case "response.output_item.added", "response.output_item.done":
            var events = usageEvents
            if let item = object["item"] as? [String: Any] {
                if RemoteGenerationClient.isResponseToolCallItem(item) {
                    events.append(
                        .responseToolCallItem(
                            item,
                            outputIndex: RemoteGenerationClient.integerValue(object["output_index"])
                        )
                    )
                } else if RemoteGenerationClient.isResponseReasoningItem(item) {
                    if type == "response.output_item.done" {
                        events.append(.responseReasoningItem(item))
                    }
                } else if type == "response.output_item.done",
                          let text = RemoteGenerationClient.responseOutputText(from: item)?.nilIfBlank {
                    events.append(.contentSnapshot(text))
                }
            }
            return events.isEmpty ? [.ignored] : events
        case "response.function_call_arguments.delta":
            usageEvents.append(.responseToolCallArgumentsDelta(object))
            return usageEvents
        case "response.function_call_arguments.done":
            usageEvents.append(.responseToolCallArgumentsDone(object))
            return usageEvents
        case "response.completed", "response.done":
            var events = usageEvents
            if let response = object["response"] as? [String: Any] {
                appendResponseOutputEvents(
                    from: response,
                    includeToolCalls: true,
                    to: &events
                )
            }
            events.append(.stop("end_turn"))
            return events
        case "response.incomplete":
            var events = usageEvents
            if let response = object["response"] as? [String: Any] {
                appendResponseOutputEvents(
                    from: response,
                    includeToolCalls: false,
                    to: &events
                )
            }
            events.append(.discardToolCalls)
            events.append(.stop(responseIncompleteStopReason(from: object)))
            return events
        case "response.failed":
            usageEvents.append(
                .failure(
                    RemoteStreamTransport.responseFailureMessage(
                        from: object,
                        fallbackType: type
                    )
                )
            )
            return usageEvents
        default:
            return usageEvents.isEmpty ? [.ignored] : usageEvents
        }
    }

    // MARK: - Output events

    private static func appendResponseOutputEvents(
        from response: [String: Any],
        includeToolCalls: Bool,
        to events: inout [ParsedRemoteStreamEvent]
    ) {
        let canonicalOutputText = streamContentText(from: response["output_text"])?.nilIfBlank
        if let outputText = canonicalOutputText {
            events.append(.contentSnapshot(outputText))
        }
        guard let outputItems = response["output"] as? [[String: Any]] else {
            return
        }
        var outputItemText = ""
        for (index, item) in outputItems.enumerated() {
            if includeToolCalls, RemoteGenerationClient.isResponseToolCallItem(item) {
                events.append(.responseToolCallItem(item, outputIndex: index))
            } else if RemoteGenerationClient.isResponseReasoningItem(item) {
                events.append(.responseReasoningItem(item))
            } else if let text = RemoteGenerationClient.responseOutputText(from: item)?.nilIfBlank {
                outputItemText.append(text)
            }
        }
        if canonicalOutputText == nil,
           let snapshot = outputItemText.nilIfBlank {
            events.append(.contentSnapshot(snapshot))
        }
    }

    // MARK: - Stop reason

    private static func responseIncompleteStopReason(from object: [String: Any]) -> String {
        let response = object["response"] as? [String: Any]
        let details = response?["incomplete_details"] as? [String: Any]
            ?? object["incomplete_details"] as? [String: Any]
        return RemoteGenerationClient.stringValue(details?["reason"])?.nilIfBlank
            ?? RemoteGenerationClient.stringValue(response?["status"])?.nilIfBlank
            ?? "incomplete"
    }

    // MARK: - Content-part helpers

    private static func responseContentPartDelta(from object: [String: Any]) -> String? {
        if let delta = responseContentPartText(from: object["delta"]) {
            return delta
        }
        return responseContentPartText(from: object)
    }

    private static func responseContentPartText(from value: Any?) -> String? {
        if let text = streamContentText(from: value)?.nilIfBlank {
            return text
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        let type = RemoteGenerationClient.stringValue(object["type"])?.lowercased() ?? ""
        guard !type.contains("reasoning") else {
            return nil
        }
        return streamContentText(from: object["text"])?.nilIfBlank
            ?? streamContentText(from: object["content"])?.nilIfBlank
            ?? streamContentText(from: object["delta"])?.nilIfBlank
    }

    // MARK: - Generic content text

    public static func streamContentText(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let items = value as? [[String: Any]] {
            let text = items
                .compactMap { item -> String? in
                    if let text = item["text"] as? String {
                        return text
                    }
                    return item["content"] as? String
                }
                .joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    // MARK: - Tool payloads

    /// Builds the `tools` payload array for the `/responses` endpoint.
    public static func toolPayloads(
        from descriptors: [DirectToolDescriptor]
    ) -> [[String: Any]] {
        descriptors.compactMap { descriptor in
            guard let schema = descriptor.schemaObject else {
                return nil
            }
            return [
                "type": "function",
                "name": descriptor.name,
                "description": descriptor.description,
                "parameters": schema,
                "strict": false
            ]
        }
    }
}
