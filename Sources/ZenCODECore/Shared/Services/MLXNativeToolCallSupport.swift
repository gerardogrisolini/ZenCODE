//
//  MLXNativeToolCallSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated struct MLXNativeToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
}

public nonisolated enum MLXNativeToolCallSupport {
    public static func toolNames(
        from values: [String?]
    ) -> Set<String> {
        Set(values.compactMap(nonBlank))
    }

    public static func nonBlank(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    public static func resolvedToolCall(
        from content: String,
        allowedToolNames: Set<String>,
        allowsAnyToolName: Bool = false
    ) -> MLXNativeToolCall? {
        guard allowsAnyToolName || !allowedToolNames.isEmpty else {
            return nil
        }

        guard let request = parsedToolRequest(from: content) else {
            return nil
        }

        guard allowsAnyToolName || isAllowedToolName(
            request.name,
            allowedToolNames: allowedToolNames
        ) else {
            return nil
        }

        return MLXNativeToolCall(
            id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            name: request.name,
            argumentsJSON: request.argumentsJSON
        )
    }

    public static func normalizedAssistantTranscriptIfToolCall(
        from content: String,
        allowedToolNames: Set<String>,
        allowsAnyToolName: Bool = false
    ) -> String? {
        guard let toolCall = resolvedToolCall(
            from: content,
            allowedToolNames: allowedToolNames,
            allowsAnyToolName: allowsAnyToolName
        ) else {
            return nil
        }

        return assistantToolCallTranscript(
            name: toolCall.name,
            argumentsJSON: toolCall.argumentsJSON
        )
    }

    public static func assistantToolCallTranscript(
        name: String,
        argumentsJSON: String
    ) -> String {
        let payload: [String: Any] = [
            "tool": name,
            "arguments": argumentsObject(from: argumentsJSON)
        ]
        guard let data = try? JSONValue(jsonObject: payload).jsonData(
            outputFormatting: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return #"{"arguments":{},"tool":"\#(name)"}"#
        }

        return String(decoding: data, as: UTF8.self)
    }

    public static func toolResultTranscript(
        callID: String?,
        name: String?,
        output: String
    ) -> String {
        let resolvedName = nonBlank(name)
        let resolvedCallID = nonBlank(callID)
        let title: String
        switch (resolvedName, resolvedCallID) {
        case let (name?, callID?):
            title = "Tool result for \(name) (\(callID)):"
        case let (name?, nil):
            title = "Tool result for \(name):"
        case let (nil, callID?):
            title = "Tool result for \(callID):"
        case (nil, nil):
            title = "Tool result:"
        }

        return "\(title)\n\(output)"
    }

    public static func responseFunctionCallItem(
        id: String,
        callID: String,
        name: String,
        argumentsJSON: String,
        status: String
    ) -> [String: Any] {
        [
            "id": id,
            "type": "function_call",
            "status": status,
            "call_id": callID,
            "name": name,
            "arguments": argumentsJSON
        ]
    }

    public static func chatToolCallPayload(
        from toolCall: MLXNativeToolCall
    ) -> [String: Any] {
        [
            "id": toolCall.id,
            "type": "function",
            "function": [
                "name": toolCall.name,
                "arguments": toolCall.argumentsJSON
            ]
        ]
    }

    public static func chatToolCallDeltaPayload(
        from toolCall: MLXNativeToolCall
    ) -> [String: Any] {
        var payload = chatToolCallPayload(from: toolCall)
        payload["index"] = 0
        return payload
    }

    private static func isAllowedToolName(
        _ toolName: String,
        allowedToolNames: Set<String>
    ) -> Bool {
        let normalizedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            return false
        }

        if allowedToolNames.contains(normalizedName) {
            return true
        }

        if allowedToolNames.contains(remoteToolWireName(for: normalizedName)) {
            return true
        }

        if allowedToolNames.map(remoteToolWireName(for:)).contains(normalizedName) {
            return true
        }

        if allowedToolNames.contains(where: { allowedName in
            allowedName.hasSuffix(".") && normalizedName.hasPrefix(allowedName)
        }) {
            return true
        }

        for prefix in ["xcode.", "figma."] where normalizedName.hasPrefix(prefix) {
            let unprefixedName = String(normalizedName.dropFirst(prefix.count))
            if allowedToolNames.contains(unprefixedName) {
                return true
            }
        }

        return false
    }

    private static func parsedToolRequest(
        from content: String
    ) -> (name: String, argumentsJSON: String)? {
        let trimmedContent = normalizedToolCallText(from: content)
        let jsonText = unwrappedToolJSONText(from: trimmedContent)
        if let request = decodedToolRequest(from: jsonText) {
            return request
        }

        let candidates = extractBalancedJSONObjects(from: trimmedContent)
            .compactMap { decodedToolRequest(from: $0) }
        guard candidates.count == 1 else {
            return nil
        }

        return candidates[0]
    }

    private static func decodedToolRequest(
        from jsonText: String
    ) -> (name: String, argumentsJSON: String)? {
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(object) = root else {
            return nil
        }

        if let toolName = nonBlank(
            object["tool"]?.stringValue ?? object["name"]?.stringValue
        ) {
            return (
                toolName,
                decodedToolArguments(from: object).prettyPrinted()
            )
        }

        return decodedToolRequestWithNestedToolName(from: object)
    }

    private static func decodedToolArguments(
        from object: [String: JSONValue]
    ) -> JSONValue {
        if let explicitArguments = object["arguments"] ?? object["input"],
           case .object = explicitArguments {
            return explicitArguments
        }

        let reservedKeys = Set(["tool", "name", "arguments", "input"])
        return .object(
            object.filter { key, _ in
                !reservedKeys.contains(key)
            }
        )
    }

    private static func decodedToolRequestWithNestedToolName(
        from object: [String: JSONValue]
    ) -> (name: String, argumentsJSON: String)? {
        decodedToolRequestWithNestedToolName(
            from: object,
            argumentKey: "arguments"
        ) ?? decodedToolRequestWithNestedToolName(
            from: object,
            argumentKey: "input"
        )
    }

    private static func decodedToolRequestWithNestedToolName(
        from object: [String: JSONValue],
        argumentKey: String
    ) -> (name: String, argumentsJSON: String)? {
        guard let explicitArguments = object[argumentKey],
              case let .object(nestedArguments) = explicitArguments,
              let toolName = nonBlank(
                  nestedArguments["tool"]?.stringValue
                    ?? nestedArguments["name"]?.stringValue
              ) else {
            return nil
        }

        let nestedReservedKeys = Set(["tool", "name"])
        var mergedArguments = nestedArguments.filter { key, _ in
            !nestedReservedKeys.contains(key)
        }

        let topLevelReservedKeys = Set(["tool", "name", "arguments", "input"])
        for (key, value) in object where !topLevelReservedKeys.contains(key) {
            if mergedArguments[key] == nil {
                mergedArguments[key] = value
            }
        }

        return (
            toolName,
            JSONValue.object(mergedArguments).prettyPrinted()
        )
    }

    private static func extractBalancedJSONObjects(
        from text: String
    ) -> [String] {
        var objects: [String] = []
        var startIndex: String.Index?
        var depth = 0
        var isInString = false
        var isEscaped = false

        for index in text.indices {
            let character = text[index]

            if isInString {
                if isEscaped {
                    isEscaped = false
                                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }

            if character == "\"" {
                isInString = true
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let objectStartIndex = startIndex {
                    objects.append(String(text[objectStartIndex ... index]))
                    startIndex = nil
                }
            }
        }

        return objects
    }

    private static func normalizedToolCallText(from content: String) -> String {
        stripThinkingSegments(from: content)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "<tool_call>", with: "")
            .replacingOccurrences(of: "</tool_call>", with: "")
            .replacingOccurrences(of: "<|tool_call>", with: "")
            .replacingOccurrences(of: "<tool_call|>", with: "")
            .replacingOccurrences(of: "<function>", with: "")
            .replacingOccurrences(of: "</function>", with: "")
            .replacingOccurrences(of: "<function_call>", with: "")
            .replacingOccurrences(of: "</function_call>", with: "")
            .replacingOccurrences(of: "<start_function_call>", with: "")
            .replacingOccurrences(of: "<end_function_call>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ThinkingTag {
        let range: Range<String.Index>
        let isOpening: Bool
    }

    private static func stripThinkingSegments(from content: String) -> String {
        var output = ""
        var cursor = content.startIndex

        while cursor < content.endIndex {
            guard let tag = nextThinkingTag(in: content, from: cursor) else {
                output.append(contentsOf: content[cursor...])
                break
            }

            if tag.isOpening {
                output.append(contentsOf: content[cursor ..< tag.range.lowerBound])
                cursor = tag.range.upperBound

                guard let closingRange = nextThinkingClosingRange(in: content, from: cursor) else {
                    break
                }
                cursor = closingRange.upperBound
            } else {
                cursor = tag.range.upperBound
            }
        }

        return output
    }

    private static func nextThinkingTag(
        in content: String,
        from cursor: String.Index
    ) -> ThinkingTag? {
        let searchRange = cursor ..< content.endIndex
        let candidates: [ThinkingTag] = [
            thinkingTag("<think>", in: content, range: searchRange, isOpening: true),
            thinkingTag("<think ", in: content, range: searchRange, isOpening: true),
            thinkingTag("</think>", in: content, range: searchRange, isOpening: false),
            thinkingTag("<thinking>", in: content, range: searchRange, isOpening: true),
            thinkingTag("<thinking ", in: content, range: searchRange, isOpening: true),
            thinkingTag("</thinking>", in: content, range: searchRange, isOpening: false),
            thinkingTag("<|think|>", in: content, range: searchRange, isOpening: true),
            thinkingTag("<|channel>thought", in: content, range: searchRange, isOpening: true),
            thinkingTag("<channel|>", in: content, range: searchRange, isOpening: false)
        ].compactMap { $0 }

        return candidates.min { lhs, rhs in
            lhs.range.lowerBound < rhs.range.lowerBound
        }
    }

    private static func thinkingTag(
        _ marker: String,
        in content: String,
        range searchRange: Range<String.Index>,
        isOpening: Bool
    ) -> ThinkingTag? {
        content.range(
            of: marker,
            options: [.caseInsensitive],
            range: searchRange
        ).map {
            ThinkingTag(range: $0, isOpening: isOpening)
        }
    }

    private static func nextThinkingClosingRange(
        in content: String,
        from cursor: String.Index
    ) -> Range<String.Index>? {
        let searchRange = cursor ..< content.endIndex
        return ["</think>", "</thinking>", "<channel|>"]
            .compactMap { marker in
                content.range(
                    of: marker,
                    options: [.caseInsensitive],
                    range: searchRange
                )
            }
            .min { lhs, rhs in
                lhs.lowerBound < rhs.lowerBound
            }
    }

    private static func unwrappedToolJSONText(
        from content: String
    ) -> String {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fencedContent = unwrappedCodeFenceToolJSONText(from: trimmedContent) {
            return fencedContent
        }

        let wrappers = [
            ("<tool_call>", "</tool_call>"),
            ("<function_call>", "</function_call>"),
            ("<start_function_call>", "<end_function_call>")
        ]

        for wrapper in wrappers {
            if trimmedContent.hasPrefix(wrapper.0),
               trimmedContent.hasSuffix(wrapper.1) {
                let start = trimmedContent.index(
                    trimmedContent.startIndex,
                    offsetBy: wrapper.0.count
                )
                let end = trimmedContent.index(
                    trimmedContent.endIndex,
                    offsetBy: -wrapper.1.count
                )
                return String(trimmedContent[start ..< end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmedContent
    }

    private static func unwrappedCodeFenceToolJSONText(
        from content: String
    ) -> String? {
        guard content.hasPrefix("```"),
              content.hasSuffix("```"),
              let firstLineEnd = content.firstIndex(of: "\n") else {
            return nil
        }

        let bodyStart = content.index(after: firstLineEnd)
        let bodyEnd = content.index(content.endIndex, offsetBy: -3)
        guard bodyStart <= bodyEnd else {
            return nil
        }

        return String(content[bodyStart ..< bodyEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func remoteToolWireName(
        for toolName: String
    ) -> String {
        var body = ""
        var lastCharacterWasSeparator = false

        for scalar in toolName.unicodeScalars {
            let isAlphaNumeric =
                CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_"

            if isAlphaNumeric {
                body.unicodeScalars.append(scalar)
                lastCharacterWasSeparator = false
            } else if !lastCharacterWasSeparator {
                body.append("_")
                lastCharacterWasSeparator = true
            }
        }

        let trimmedBody = body.trimmingCharacters(
            in: CharacterSet(charactersIn: "_")
        )
        guard !trimmedBody.isEmpty else {
            return "tool"
        }

        return "tool_\(trimmedBody)"
    }

    private static func argumentsObject(
        from argumentsJSON: String
    ) -> Any {
        let trimmedArguments = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArguments.isEmpty,
              let data = trimmedArguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return [:] as [String: Any]
        }

        return value.jsonObject
    }
}
