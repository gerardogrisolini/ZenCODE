//
//  AgentToolTurnTranscriptSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct AgentToolTurnTranscriptToolCall {
    public let name: String
    public let argumentsObject: [String: Any]
    public let argumentsJSON: String

    public init(name: String, argumentsObject: [String: Any]) {
        self.name = name
        let compatible = AgentJSONSupport.jsonCompatible(argumentsObject)
        self.argumentsObject = compatible as? [String: Any] ?? [:]
        self.argumentsJSON = AgentJSONSupport.jsonString(from: self.argumentsObject)
    }

    public init(name: String, argumentsJSON: String) {
        self.init(
            name: name,
            argumentsObject: AgentJSONSupport.object(from: argumentsJSON) ?? [:]
        )
    }
}

public struct AgentToolTurnTranscriptToolResult {
    public let name: String
    public let argumentsJSON: String
    public let output: String

    public init(name: String, argumentsJSON: String, output: String) {
        let toolCall = AgentToolTurnTranscriptToolCall(
            name: name,
            argumentsJSON: argumentsJSON
        )
        self.name = toolCall.name
        self.argumentsJSON = toolCall.argumentsJSON
        self.output = output
    }

    public init(toolCall: AgentToolTurnTranscriptToolCall, output: String) {
        self.name = toolCall.name
        self.argumentsJSON = toolCall.argumentsJSON
        self.output = output
    }
}

public enum AgentToolTurnTranscriptSupport {
    public static func assistantTranscript(
        content: String,
        toolCalls: [AgentToolTurnTranscriptToolCall]
    ) -> String {
        var segments: [String] = []
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContent.isEmpty {
            segments.append(trimmedContent)
        }

        for toolCall in toolCalls {
            segments.append(toolCallJSON(toolCall))
        }
        return segments.joined(separator: "\n\n")
    }

    public static func toolCallJSON(
        name: String,
        argumentsJSON: String
    ) -> String {
        toolCallJSON(
            AgentToolTurnTranscriptToolCall(
                name: name,
                argumentsJSON: argumentsJSON
            )
        )
    }

    public static func renderedToolOutput(name: String, output: String) -> String {
        """
        Tool executed:
        \(name)

        Tool result:
        \(output)
        """
    }

    public static func toolFollowUpPrompt(
        userRequest: String,
        toolResults: [AgentToolTurnTranscriptToolResult]
    ) -> String {
        if toolResults.count == 1, let toolResult = toolResults.first {
            return """
            You previously asked to run a tool.

            User request:
            \(userRequest)

            Tool executed:
            \(toolResult.name)

            Arguments:
            \(toolResult.argumentsJSON)

            Tool result:
            \(toolResult.output)

            If the tool result is sufficient, answer the user's request directly.
            If you still need another available tool, call it using the model's native tool-call format.
            """
        }

        let renderedResults = toolResults.map { toolResult in
            """
            Tool executed:
            \(toolResult.name)

            Arguments:
            \(toolResult.argumentsJSON)

            Tool result:
            \(toolResult.output)
            """
        }
        .joined(separator: "\n\n")

        return """
        You previously asked to run multiple tools.

        User request:
        \(userRequest)

        \(renderedResults)

        If the tool results are sufficient, answer the user's request directly.
        If you still need another available tool, call it using the model's native tool-call format.
        """
    }

    public static func toolCalls(
        fromRenderedToolCalls text: String
    ) -> [AgentToolTurnTranscriptToolCall] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return []
        }

        let jsonCalls = jsonObjectStrings(in: trimmedText)
            .compactMap(toolCallFromJSONObjectText)
        if !jsonCalls.isEmpty {
            return jsonCalls
        }

        return []
    }

    public static func toolResults(
        fromRenderedToolOutput text: String,
        matching toolCalls: [AgentToolTurnTranscriptToolCall]
    ) -> [AgentToolTurnTranscriptToolResult] {
        let parsedBlocks = toolOutputBlocks(from: text)
        guard !parsedBlocks.isEmpty else {
            return []
        }

        return parsedBlocks.enumerated().map { index, block in
            let fallbackToolCall = matchingToolCall(
                for: block.name,
                at: index,
                in: toolCalls
            )
            return AgentToolTurnTranscriptToolResult(
                name: block.name.nilIfBlank ?? fallbackToolCall?.name ?? "Tool",
                argumentsJSON: block.argumentsJSON
                    ?? fallbackToolCall?.argumentsJSON
                    ?? "{}",
                output: block.output
            )
        }
    }

    private static func toolCallJSON(
        _ toolCall: AgentToolTurnTranscriptToolCall
    ) -> String {
        AgentJSONSupport.jsonString(
            from: [
                "tool": toolCall.name,
                "arguments": toolCall.argumentsObject
            ]
        )
    }

    private static func toolCallFromJSONObjectText(
        _ text: String
    ) -> AgentToolTurnTranscriptToolCall? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.mlxObjectValue?.mapValues(\.jsonObject) else {
            return nil
        }

        let toolName = (object["tool"] as? String ?? object["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let toolName, !toolName.isEmpty else {
            return nil
        }

        let argumentsObject: [String: Any]
        if let objectArguments = object["arguments"] as? [String: Any] {
            argumentsObject = objectArguments
        } else if let argumentsJSON = object["arguments"] as? String {
            argumentsObject = AgentJSONSupport.object(from: argumentsJSON) ?? [:]
        } else {
            argumentsObject = [:]
        }

        return AgentToolTurnTranscriptToolCall(
            name: toolName,
            argumentsObject: argumentsObject
        )
    }

    private static func matchingToolCall(
        for name: String,
        at index: Int,
        in toolCalls: [AgentToolTurnTranscriptToolCall]
    ) -> AgentToolTurnTranscriptToolCall? {
        if toolCalls.indices.contains(index),
           toolCalls[index].name == name {
            return toolCalls[index]
        }

        return toolCalls.first { $0.name == name }
            ?? (toolCalls.indices.contains(index) ? toolCalls[index] : nil)
    }

    private static func toolOutputBlocks(
        from text: String
    ) -> [(name: String, argumentsJSON: String?, output: String)] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return []
        }

        let marker = "Tool executed:\n"
        let resultMarker = "\n\nTool result:\n"
        var blocks: [(name: String, argumentsJSON: String?, output: String)] = []
        var searchStart = trimmedText.startIndex

        while let markerRange = trimmedText.range(
            of: marker,
            range: searchStart ..< trimmedText.endIndex
        ) {
            let headerStart = markerRange.upperBound
            guard let resultRange = trimmedText.range(
                of: resultMarker,
                range: headerStart ..< trimmedText.endIndex
            ) else {
                break
            }

            let outputStart = resultRange.upperBound
            let nextMarker = trimmedText.range(
                of: "\n\n\(marker)",
                range: outputStart ..< trimmedText.endIndex
            )
            let outputEnd = nextMarker?.lowerBound ?? trimmedText.endIndex
            let header = String(trimmedText[headerStart ..< resultRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let output = String(trimmedText[outputStart ..< outputEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedHeader = parseToolOutputHeader(header)

            blocks.append(
                (
                    name: parsedHeader.name,
                    argumentsJSON: parsedHeader.argumentsJSON,
                    output: output
                )
            )

            guard let nextMarker else {
                break
            }
            searchStart = trimmedText.index(nextMarker.lowerBound, offsetBy: 2)
        }

        return blocks
    }

    private static func parseToolOutputHeader(
        _ header: String
    ) -> (name: String, argumentsJSON: String?) {
        let argumentMarker = "\n\nArguments:\n"
        guard let argumentsRange = header.range(of: argumentMarker) else {
            return (
                name: header.trimmingCharacters(in: .whitespacesAndNewlines),
                argumentsJSON: nil
            )
        }

        let name = String(header[..<argumentsRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let argumentsJSON = String(header[argumentsRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        return (name: name, argumentsJSON: argumentsJSON)
    }

    private static func splitParagraphBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var currentLines: [String] = []

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !currentLines.isEmpty {
                    blocks.append(currentLines.joined(separator: "\n"))
                    currentLines.removeAll(keepingCapacity: true)
                }
            } else {
                currentLines.append(line)
            }
        }

        if !currentLines.isEmpty {
            blocks.append(currentLines.joined(separator: "\n"))
        }

        return blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func jsonObjectStrings(in text: String) -> [String] {
        var objects: [String] = []
        var depth = 0
        var startIndex: String.Index?
        var isInsideString = false
        var isEscaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let objectStartIndex = startIndex {
                    objects.append(String(text[objectStartIndex ... index]))
                    startIndex = nil
                } else if depth < 0 {
                    depth = 0
                    startIndex = nil
                }
            }

            index = text.index(after: index)
        }

        return objects
    }
}

public enum AgentJSONSupport {
    public static func jsonString(from value: Any) -> String {
        JSONValue(jsonObject: value).compactString(sortedKeys: true)
    }

    public static func object(from json: String) -> [String: Any]? {
        let trimmedJSON = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJSON.isEmpty,
              let data = trimmedJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.mlxObjectValue else {
            return nil
        }

        return object.mapValues(\.jsonObject)
    }

    public static func jsonCompatible(_ value: Any) -> Any {
        JSONValue(jsonObject: value).jsonObject
    }
}
