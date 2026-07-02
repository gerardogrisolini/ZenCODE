//
//  ToolRequestCompatibilitySupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated func assignString(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstStringValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .string(value)
}

public nonisolated func assignPathString(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstStringValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .string(normalizedToolPathString(value))
}

public nonisolated func assignXcodeSnippetString(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstStringValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .string(normalizedXcodeSnippetString(value))
}

public nonisolated func assignNormalizedTextEditOperations(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstJSONValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = normalizedTextEditOperations(value)
}

public nonisolated func assignStringArray(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let values = firstStringArrayValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .array(values.map(JSONValue.string))
}

public nonisolated func assignNumber(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstNumberValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .number(value)
}

public nonisolated func assignBool(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstBoolValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .bool(value)
}

public nonisolated func assignJSON(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstJSONValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = value
}

nonisolated func assignNormalizedXcodeTestSpecifiers(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstJSONValue(sourceKeys, in: arguments),
          let normalizedValue = normalizedXcodeTestSpecifiers(value) else {
        return
    }

    normalized[destinationKey] = normalizedValue
}

nonisolated func firstStringValue(
    _ keys: [String],
    in arguments: [String: JSONValue]
) -> String? {
    for key in keys {
        guard let value = arguments[key] else {
            continue
        }

        switch value {
        case let .string(string):
            return string
        case let .number(number):
            if floor(number) == number {
                return String(Int(number))
            }
            return String(number)
        case let .bool(bool):
            return bool ? "true" : "false"
        default:
            continue
        }
    }

    return nil
}

nonisolated func normalizedToolPathString(
    _ rawValue: String
) -> String {
    normalizedToolPathString(rawValue, workspaceRootPath: nil)
}

nonisolated func normalizedToolPathString(
    _ rawValue: String,
    workspaceRootPath: String?
) -> String {
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else {
        return rawValue
    }

    let resolvedValue: String
    if trimmedValue.hasPrefix("file://"),
       let url = URL(string: trimmedValue),
       url.isFileURL {
        resolvedValue = url.path
    } else {
        resolvedValue = trimmedValue
    }

    guard !resolvedValue.hasPrefix("/") else {
        return resolvedValue
    }

    let normalizedSeparators = resolvedValue
        .replacingOccurrences(of: "\\", with: "/")
        .replacingOccurrences(
            of: #"^\./"#,
            with: "",
            options: .regularExpression
        )

    var components = normalizedSeparators
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)

    while components.count >= 2,
          components[0] == components[1],
          !components[0].contains(".") {
        components.removeFirst()
    }

    guard !components.isEmpty else {
        return normalizedSeparators
    }

    let normalizedRelativePath = components.joined(separator: "/")
    if let rebasedPath = normalizedWorkspaceRelativeToolPath(
        normalizedRelativePath,
        workspaceRootPath: workspaceRootPath
    ) {
        return rebasedPath
    }

    return normalizedRelativePath
}

public nonisolated func rebasedWorkspaceRelativePaths(
    in request: ToolRequest,
    workspaceRootPath: String?
) -> ToolRequest {
    guard toolRequestUsesWorkspaceRelativePaths(request.name),
          let workspaceRootPath = normalizedWorkspaceRootPath(workspaceRootPath) else {
        return request
    }

    let rebasedArguments = request.arguments.reduce(into: [String: JSONValue]()) { partialResult, entry in
        guard workspaceRelativePathArgumentKeys.contains(entry.key),
              let stringValue = entry.value.stringValue else {
            partialResult[entry.key] = entry.value
            return
        }

        partialResult[entry.key] = .string(
            normalizedToolPathString(stringValue, workspaceRootPath: workspaceRootPath)
        )
    }

    return ToolRequest(
        name: request.name,
        arguments: rebasedArguments
    )
}

public nonisolated func rebasedSkillRelativePaths(
    in request: ToolRequest,
    workspaceRootPath: String?,
    skillRootPaths: [String]
) -> ToolRequest {
    guard toolRequestUsesSkillRelativePaths(request.name) else {
        return request
    }

    let normalizedSkillRootURLs = skillRootPaths.compactMap { rawPath -> URL? in
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: trimmedPath).standardizedFileURL
    }
    guard !normalizedSkillRootURLs.isEmpty else {
        return request
    }

    let workspaceRootURL = normalizedWorkspaceRootPath(workspaceRootPath).map {
        URL(fileURLWithPath: $0).standardizedFileURL
    }

    let rebasedArguments = request.arguments.reduce(into: [String: JSONValue]()) { partialResult, entry in
        guard workspaceRelativePathArgumentKeys.contains(entry.key),
              let stringValue = entry.value.stringValue else {
            partialResult[entry.key] = entry.value
            return
        }

        let normalizedPath = normalizedToolPathString(
            stringValue,
            workspaceRootPath: workspaceRootPath
        )
        guard !normalizedPath.hasPrefix("/") else {
            partialResult[entry.key] = .string(normalizedPath)
            return
        }

        if let workspaceRootURL {
            let workspaceCandidateURL = workspaceRootURL
                .appendingPathComponent(normalizedPath)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: workspaceCandidateURL.path) {
                partialResult[entry.key] = .string(normalizedPath)
                return
            }
        }

        if let skillResolvedPath = resolvedSkillRelativeToolPath(
            normalizedPath,
            skillRootURLs: normalizedSkillRootURLs
        ) {
            partialResult[entry.key] = .string(skillResolvedPath)
        } else {
            partialResult[entry.key] = .string(normalizedPath)
        }
    }

    return ToolRequest(
        name: request.name,
        arguments: rebasedArguments
    )
}
