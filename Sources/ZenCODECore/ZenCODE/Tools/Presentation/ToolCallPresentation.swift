//
//  ToolCallPresentation.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Shared presentation metadata for direct-agent tool calls.
public enum ToolCallPresentation {
    public static func resolved(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult? = nil,
        mode: ToolPresentationMode
    ) -> ResolvedToolPresentation {
        ToolPresentationResolver.resolve(
            call: toolCall,
            result: result,
            mode: mode
        )
    }

    public static func toolTitle(for toolCall: DirectAgentToolCall) -> String {
        if toolCall.presentation != nil {
            let presentation = resolved(for: toolCall, mode: .compact)
            let target = compactDisplayTarget(
                for: toolCall,
                presentation: presentation
            )
            if let action = presentation.action,
               let target {
                return "\(action) \(target)"
            }
            if let target {
                return "\(presentation.title) \(target)"
            }
            return presentation.action ?? presentation.title
        }
        return toolCall.name
    }

    public static func toolKind(for toolCall: DirectAgentToolCall) -> String {
        guard toolCall.presentation != nil else {
            return ToolPresentationKind.other.rawValue
        }
        return resolved(for: toolCall, mode: .compact).kind.rawValue
    }

    public static func xcodeToolKind(for rawName: String) -> String {
        XcodeToolIntegration.presentationKind(for: rawName)
    }

    public static func toolIcon(for toolName: String) -> String {
        "🛠️"
    }

    private static let locationStringArgumentKeys = [
        "path",
        "file_path",
        "sourcePath",
        "destinationPath",
        "workingDirectory",
        "cwd",
        "filePath",
        "sourceFilePath",
        "directoryPath"
    ]

    private static let readFilesPathArrayArgumentKeys = ["paths", "file_paths"]

    /// Conservative, name-independent fallback keys for compact rendering.
    /// Payload-like fields such as `content`, `message`, `prompt`, credentials,
    /// and tokens are deliberately excluded: a tool that wants to expose one of
    /// those values must opt in through its own presentation definition.
    private static let compactFallbackStringArgumentKeys = [
        "file_path",
        "filePath",
        "file_name",
        "fileName",
        "filename",
        "file",
        "sourceFilePath",
        "sourcePath",
        "destinationPath",
        "directoryPath",
        "path",
        "workingDirectory",
        "working_directory",
        "cwd",
        "identifier",
        "id",
        "name",
        "query",
        "pattern",
        "command",
        "url",
        "uri"
    ]

    public static func toolLocations(for toolCall: DirectAgentToolCall) -> [[String: Any]] {
        var seen = Set<String>()
        var locations: [[String: Any]] = []

        appendLocations(
            stringArguments(from: toolCall.argumentsObject, keys: locationStringArgumentKeys),
            seen: &seen,
            locations: &locations
        )
        if toolCall.name == "local.readFiles" {
            appendLocations(
                pathArrayArguments(from: toolCall.argumentsObject, keys: readFilesPathArrayArgumentKeys),
                seen: &seen,
                locations: &locations
            )
        }
        if toolCall.name == "local.applyPatch" {
            appendLocations(
                patchPathTargets(from: toolCall.argumentsObject),
                seen: &seen,
                locations: &locations
            )
        }
        return locationsWithoutAncestorDuplicates(locations)
    }

    private static func appendLocations(
        _ paths: [String],
        seen: inout Set<String>,
        locations: inout [[String: Any]]
    ) {
        for path in paths {
            let normalizedPath = URL(fileURLWithPath: path)
                .standardizedFileURL
                .path
            guard seen.insert(normalizedPath).inserted else {
                continue
            }
            locations.append(["path": normalizedPath])
        }
    }

    private static func locationsWithoutAncestorDuplicates(
        _ locations: [[String: Any]]
    ) -> [[String: Any]] {
        locations.filter { location in
            guard let path = location["path"] as? String else {
                return true
            }
            return !locations.contains { candidate in
                guard let candidatePath = candidate["path"] as? String else {
                    return false
                }
                return isAncestorLocation(path, of: candidatePath)
            }
        }
    }

    private static func isAncestorLocation(
        _ ancestorPath: String,
        of descendantPath: String
    ) -> Bool {
        let ancestor = URL(fileURLWithPath: ancestorPath)
            .standardizedFileURL
            .path
        let descendant = URL(fileURLWithPath: descendantPath)
            .standardizedFileURL
            .path
        guard ancestor != descendant else {
            return false
        }
        guard ancestor != "/" else {
            return descendant.hasPrefix("/")
        }
        return descendant.hasPrefix("\(ancestor)/")
    }

    public static func displayToolTarget(for toolCall: DirectAgentToolCall) -> String? {
        guard toolCall.presentation != nil else {
            return nil
        }
        return compactDisplayTarget(
            for: toolCall,
            presentation: resolved(for: toolCall, mode: .compact)
        )
    }

    /// Keeps a compact tool call from degrading to a context-free verb such as
    /// `List`, `Inspect`, or `Write`. The tool-owned target remains authoritative;
    /// a safe scalar argument is used only when that target is absent, followed
    /// by the tool-owned semantic title for genuinely argument-less operations.
    private static func compactDisplayTarget(
        for toolCall: DirectAgentToolCall,
        presentation: ResolvedToolPresentation
    ) -> String? {
        if let target = presentation.target?.nilIfBlank {
            return target
        }
        if let argument = fallbackArgumentTarget(for: toolCall) {
            return argument
        }
        guard let action = presentation.action?.nilIfBlank,
              let title = presentation.title.nilIfBlank,
              title.caseInsensitiveCompare(action) != .orderedSame else {
            return nil
        }
        return title
    }

    private static func fallbackArgumentTarget(
        for toolCall: DirectAgentToolCall
    ) -> String? {
        stringArgument(
            toolCall.argumentsObject,
            keys: compactFallbackStringArgumentKeys
        )
    }

    private static func stringArguments(
        from arguments: [String: Any],
        keys: [String]
    ) -> [String] {
        keys.compactMap { key in
            (arguments[key] as? String)?.nilIfBlank
        }
    }

    private static func pathArrayArguments(
        from arguments: [String: Any],
        keys: [String]
    ) -> [String] {
        keys.flatMap { key in
            var paths: [String] = []
            if let rawPaths = arguments[key] as? [String] {
                paths.append(contentsOf: rawPaths.compactMap { $0.nilIfBlank })
            }
            if let rawValues = arguments[key] as? [Any] {
                paths.append(contentsOf: rawValues.compactMap { ($0 as? String)?.nilIfBlank })
            }
            return paths
        }
    }

    public static func patchDisplayTarget(from arguments: [String: Any]) -> String? {
        let targets = patchPathTargets(from: arguments)
        guard let first = targets.first else {
            return nil
        }
        guard targets.count > 1 else {
            return first
        }
        return "\(first) (+\(targets.count - 1) more)"
    }

    private static func patchPathTargets(from arguments: [String: Any]) -> [String] {
        guard let rawPatch = stringArgument(arguments, keys: ["patch", "diff"]) else {
            return []
        }
        return patchPathCandidates(from: rawPatch)
    }

    private static func patchPathCandidates(from rawPatch: String) -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []

        func appendStripped(_ value: String) {
            guard let normalized = normalizedPatchPath(value),
                  seen.insert(normalized).inserted else {
                return
            }
            candidates.append(normalized)
        }

        for rawLine in rawPatch.components(separatedBy: "\n") {
            if let value = patchSectionValue(rawLine, prefix: "*** Add File: ")
                ?? patchSectionValue(rawLine, prefix: "*** Update File: ")
                ?? patchSectionValue(rawLine, prefix: "*** Delete File: ") {
                appendStripped(value)
            } else if rawLine.hasPrefix("+++ ") {
                appendStripped(String(rawLine.dropFirst(4)))
            } else if rawLine.hasPrefix("--- ") {
                appendStripped(String(rawLine.dropFirst(4)))
            }
        }

        return candidates
    }

    private static func patchSectionValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else {
            return nil
        }
        let value = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedPatchPath(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != "/dev/null" else {
            return nil
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        guard !value.isEmpty,
              value != "/dev/null" else {
            return nil
        }
        return value
    }

    private static func stringArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = arguments[key] as? String,
               let normalizedValue = value.nilIfBlank {
                return normalizedValue
            }
            if let value = arguments[key] as? JSONValue,
               let normalizedValue = value.stringValue?.nilIfBlank {
                return normalizedValue
            }
        }
        return nil
    }


}
