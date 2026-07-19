//
//  AnthropicSubscriptionRequestBuilder.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AnthropicSubscriptionRequestBuilder {
    public static func estimatedContextTokenCount(
        system: [[String: Any]],
        messages: [[String: Any]],
        tools: [[String: Any]]
    ) -> Int? {
        var payload: [String: Any] = [:]
        if !system.isEmpty {
            payload["system"] = system
        }
        if !messages.isEmpty {
            payload["messages"] = messages
        }
        if !tools.isEmpty {
            payload["tools"] = tools
        }

        guard !payload.isEmpty,
              let data = try? JSONValue(jsonObject: sanitizedPayload(payload)).jsonData(
                  outputFormatting: [.withoutEscapingSlashes]
              ),
              !data.isEmpty else {
            return nil
        }
        return max(Int((Double(data.count) / 4.0).rounded(.up)), 1)
    }

    public static func sanitizedPayload(_ value: Any?) -> Any {
        guard let value else {
            return JSONValue.null
        }
        if let string = value as? String {
            return sanitizedString(string)
        }
        if let object = value as? [String: Any] {
            var sanitizedObject: [String: Any] = [:]
            for (key, childValue) in object {
                sanitizedObject[sanitizedString(key)] = sanitizedPayload(childValue)
            }
            return sanitizedObject
        }
        if let array = value as? [Any] {
            return array.map { sanitizedPayload($0) }
        }
        if let jsonValue = value as? JSONValue {
            return sanitizedPayload(jsonValue.jsonObject)
        }
        return value
    }

    public static func sanitizedString(_ string: String) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(string.utf16.count)

        var iterator = string.utf16.makeIterator()
        while let unit = iterator.next() {
            if (0xD800...0xDBFF).contains(unit) {
                guard let next = iterator.next() else {
                    units.append(0xFFFD)
                    break
                }
                if (0xDC00...0xDFFF).contains(next) {
                    units.append(unit)
                    units.append(next)
                } else {
                    units.append(0xFFFD)
                    if (0xD800...0xDFFF).contains(next) {
                        units.append(0xFFFD)
                    } else {
                        units.append(next)
                    }
                }
            } else if (0xDC00...0xDFFF).contains(unit) {
                units.append(0xFFFD)
            } else {
                units.append(unit)
            }
        }

        return String(decoding: units, as: UTF16.self)
    }

    public static func usage(
        from value: Any?,
        previous: RemoteGenerationUsage? = nil
    ) -> RemoteGenerationUsage? {
        guard let object = value as? [String: Any],
              let parsed = RemoteGenerationClient.parsedUsage(from: object) else {
            return previous
        }
        return mergedUsage(parsed, previous: previous)
    }

    private static func mergedUsage(
        _ usage: RemoteGenerationUsage,
        previous: RemoteGenerationUsage?
    ) -> RemoteGenerationUsage {
        let promptTokens = usage.promptTokens ?? previous?.promptTokens
        let completionTokens = usage.completionTokens ?? previous?.completionTokens
        let computedTotalTokens = sum(promptTokens, completionTokens)

        return RemoteGenerationUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: usage.totalTokens
                ?? computedTotalTokens
                ?? previous?.totalTokens,
            contextTokens: usage.contextTokens
                ?? computedTotalTokens
                ?? previous?.contextTokens,
            processedPromptTokens: usage.processedPromptTokens
                ?? previous?.processedPromptTokens,
            cachedPromptTokens: usage.cachedPromptTokens
                ?? previous?.cachedPromptTokens,
            promptTokensPerSecond: usage.promptTokensPerSecond
                ?? previous?.promptTokensPerSecond,
            completionTokensPerSecond: usage.completionTokensPerSecond
                ?? previous?.completionTokensPerSecond,
            responseDurationSeconds: usage.responseDurationSeconds
                ?? previous?.responseDurationSeconds
        )
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs + rhs
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        default:
            return nil
        }
    }
}
