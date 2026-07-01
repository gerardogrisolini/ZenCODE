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
        let failed = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Tool error:")
        return [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall.name),
            "status": failed ? "failed" : "completed",
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

    public static func toolTitle(for toolCall: DirectAgentToolCall) -> String {
        switch toolKind(for: toolCall.name) {
        case "read":
            return "Read \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "edit":
            return "Edit \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "delete":
            return "Delete \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "move":
            return "Move \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "search":
            return "Search \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "execute":
            return "Run \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        default:
            return displayToolTarget(for: toolCall).map { "\(toolCall.name) \($0)" } ?? toolCall.name
        }
    }

    public static func toolKind(for toolName: String) -> String {
        switch toolName {
        case "local.readFile", "local.readFiles", "local.ls", "local.pwd",
             "text.head", "text.tail", "text.sort", "text.wc",
             "git.status", "git.diff", "git.show", "git.log",
             "git.branch", "git.remote", "git.lsFiles", "git.grep", "git.blame":
            return "read"
        case "search.grep", "search.glob":
            return "search"
        case "local.writeFile", "local.replace", "local.append", "local.mkdir",
             "local.editFile", "local.multiEdit", "local.applyPatch":
            return "edit"
        case "local.delete":
            return "delete"
        case "local.move":
            return "move"
        case "local.exec", "git.add", "git.restore", "git.commit", "git.push",
             "git.stash", "git.switch":
            return "execute"
        case "agent.list", "agent.get", "agent.wait":
            return "read"
        case "agent.create", "agent.message", "agent.close":
            return "execute"
        default:
            if toolName.hasPrefix("xcode.") {
                return xcodeToolKind(for: String(toolName.dropFirst("xcode.".count)))
            }
            if DirectMCPToolRuntime.isXcodeToolName(toolName) {
                return xcodeToolKind(for: toolName)
            }
            switch toolName {
            case "web.search", "memory.search":
                return "search"
            case "web.fetch", "memory.read", "todo.read", "task.list", "task.get",
                 "feature.list", "feature.validate":
                return "read"
            case "memory.write", "todo.write", "task.update", "feature.scaffold",
                 "feature.install":
                return "edit"
            case "memory.archive", "feature.delete":
                return "delete"
            case "feature.enable", "feature.disable", "feature.reload", "feature.build":
                return "execute"
            default:
                break
            }
            if toolName.hasPrefix("figma.") || toolName.hasPrefix("jira.") {
                return "read"
            }
            return "other"
        }
    }

    public static func xcodeToolKind(for rawName: String) -> String {
        switch rawName {
        case "XcodeUpdate", "XcodeWrite", "XcodeMakeDir":
            return "edit"
        case "XcodeRM":
            return "delete"
        case "XcodeMV":
            return "move"
        case "BuildProject", "RunAllTests", "RunSomeTests", "ExecuteSnippet", "RenderPreview":
            return "execute"
        case "XcodeGrep", "XcodeGlob", "DocumentationSearch":
            return "search"
        default:
            return "read"
        }
    }

    public static func toolIcon(for toolName: String) -> String {
        /*
        switch toolName {
        case "local.exec":
            return "💻"
        case "local.readFile", "local.ls", "local.pwd":
            return "📄"
        case "local.writeFile", "local.replace", "local.append",
             "local.mkdir", "local.editFile", "local.multiEdit":
            return "✏️"
        case "local.delete":
            return "🗑️"
        case "local.move":
            return "↔️"
        default:
            if toolName.hasPrefix("memory.") || toolName.hasPrefix("todo.") {
                return "🧠"
            }
            if toolName.hasPrefix("agent.") || toolName.hasPrefix("task.") {
                return "👥"
            }
            if toolName.hasPrefix("git.") {
                return "🔀"
            }
            if toolName.hasPrefix("web.") {
                return "🌐"
            }
            if toolName.hasPrefix("search.") {
                return "🔎"
            }
            if toolName.hasPrefix("xcode.") || DirectMCPToolRuntime.isXcodeToolName(toolName) {
                return "🛠️"
            }
            if toolName.hasPrefix("figma.") {
                return "🎨"
            }
            if toolName.hasPrefix("jira.") {
                return "📋"
            }
            return "🔨"
        }
        */
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

    private static let displayTargetStringArgumentKeys = [
        "file_path",
        "filePath",
        "sourceFilePath",
        "sourcePath",
        "destinationPath",
        "directoryPath",
        "path",
        "command",
        "pattern"
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
        if toolCall.name == "local.applyPatch",
           let target = patchDisplayTarget(from: toolCall.argumentsObject) {
            return target
        }

        if toolCall.name == "local.readFiles" {
            return readFilesDisplayTarget(from: toolCall.argumentsObject)
        }

        return stringArguments(
            from: toolCall.argumentsObject,
            keys: displayTargetStringArgumentKeys
        ).first
    }

    private static func readFilesDisplayTarget(from arguments: [String: Any]) -> String? {
        let paths = pathArrayArguments(from: arguments, keys: readFilesPathArrayArgumentKeys)
        guard !paths.isEmpty else {
            return nil
        }
        guard paths.count > 1 else {
            return paths.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        return "\(paths.count) files"
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

    static func patchPathTargets(from arguments: [String: Any]) -> [String] {
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
