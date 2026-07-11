//
//  ToolRequestCompatibilitySupport+XcodeNormalization.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

nonisolated func normalizedXcodeSnippetString(
    _ rawValue: String
) -> String {
    let normalizedInput = unwrappedLikelyWrappedXcodeSnippetIfNeeded(from: rawValue) ?? rawValue
    return restoredLikelySwiftMemberAccessPrefixes(
        in: strippedXcodeReadPrefixesIfNeeded(from: normalizedInput)
    )
}

nonisolated func normalizedTextEditOperations(
    _ rawValue: JSONValue
) -> JSONValue {
    switch rawValue {
    case let .array(items):
        return .array(items.map(normalizedTextEditOperations))
    case let .object(object):
        let normalizedObject = object.reduce(into: [String: JSONValue]()) { partialResult, entry in
            switch entry.key {
            case "oldString", "old_string", "newString", "new_string":
                if let stringValue = entry.value.stringValue {
                    partialResult[entry.key] = .string(normalizedXcodeSnippetString(stringValue))
                } else {
                    partialResult[entry.key] = entry.value
                }
            default:
                partialResult[entry.key] = normalizedTextEditOperations(entry.value)
            }
        }
        return .object(normalizedObject)
    default:
        return rawValue
    }
}

nonisolated func normalizedXcodeTestSpecifiers(
    _ rawValue: JSONValue
) -> JSONValue? {
    switch rawValue {
    case let .array(items):
        let normalizedItems = items.compactMap(normalizedXcodeTestSpecifier)
        guard !normalizedItems.isEmpty else {
            return nil
        }
        return .array(normalizedItems)
    case .object:
        guard let normalizedSpecifier = normalizedXcodeTestSpecifier(rawValue) else {
            return nil
        }
        return .array([normalizedSpecifier])
    default:
        return nil
    }
}

nonisolated func normalizedXcodeTestSpecifier(
    _ rawValue: JSONValue
) -> JSONValue? {
    guard case let .object(object) = rawValue else {
        return nil
    }

    var normalized: [String: JSONValue] = [:]
    assignString(
        ["targetName", "target_name", "target", "testTarget", "test_target"],
        from: object,
        to: "targetName",
        in: &normalized
    )
    assignString(
        ["testIdentifier", "test_identifier", "identifier", "test", "name"],
        from: object,
        to: "testIdentifier",
        in: &normalized
    )

    guard normalized["targetName"] != nil,
          normalized["testIdentifier"] != nil else {
        return nil
    }

    return .object(normalized)
}

public nonisolated func retriedXcodeUpdateRequestForIndentationMismatch(
    originalRequest: ToolRequest,
    failureResult: JSONValue
) -> ToolRequest? {
    guard originalRequest.name == "XcodeUpdate",
          let oldString = originalRequest.arguments["oldString"]?.stringValue,
          let newString = originalRequest.arguments["newString"]?.stringValue,
          let resultObject = xcodeMutationResultObject(from: failureResult),
          xcodeMutationResultNeedsIndentationRetry(resultObject),
          let closestMatch = xcodeClosestMatchSnippetFromMessage(
              resultObject["message"]?.stringValue
          ),
          indentationInsensitiveSnippetEquivalent(oldString, closestMatch) else {
        return nil
    }

    let adjustedNewString = indentationAdjustedReplacementSnippet(
        originalOldString: oldString,
        originalNewString: newString,
        matchedOldString: closestMatch
    ) ?? newString

    guard closestMatch != oldString || adjustedNewString != newString else {
        return nil
    }

    var retriedArguments = originalRequest.arguments
    retriedArguments["oldString"] = .string(closestMatch)
    retriedArguments["newString"] = .string(adjustedNewString)
    return ToolRequest(name: originalRequest.name, arguments: retriedArguments)
}
