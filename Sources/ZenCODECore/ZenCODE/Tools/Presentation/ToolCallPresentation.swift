//
//  ToolCallPresentation.swift
//  ZenCODE
//

import Foundation

/// Shared presentation metadata for direct-agent tool calls.
public enum ToolCallPresentation {
    public static func toolTitle(for toolCall: DirectAgentToolCall) -> String {
//        switch toolKind(for: toolCall.name) {
//        case "read":
//            return "Read \(displayToolTarget(for: toolCall) ?? toolCall.name)"
//        case "edit":
//            return "Edit \(displayToolTarget(for: toolCall) ?? toolCall.name)"
//        case "delete":
//            return "Delete \(displayToolTarget(for: toolCall) ?? toolCall.name)"
//        case "move":
//            return "Move \(displayToolTarget(for: toolCall) ?? toolCall.name)"
//        case "search":
//            return "Search \(displayToolTarget(for: toolCall) ?? toolCall.name)"
//        case "execute":
//            return "Run \(displayToolTarget(for: toolCall) ?? toolCall.name)"
//        default:
            return displayToolTarget(for: toolCall).map { "\(toolCall.name) \($0)" } ?? toolCall.name
//        }
    }

    public static func toolKind(for toolName: String) -> String {
        switch toolName {
        case "local.readFile", "local.readFiles", "local.inspectFile", "local.ls", "local.pwd",
             "text.head", "text.tail", "text.sort", "text.wc",
             "git.status", "git.diff", "git.show", "git.log",
             "git.branch", "git.remote", "git.lsFiles", "git.grep", "git.blame",
             "swift.outline":
            return "read"
        case "search.grep", "search.glob", "search.locate":
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
            if XcodeToolIntegration.isToolName(toolName) {
                return XcodeToolIntegration.presentationKind(for: toolName)
            }
            switch toolName {
            case "web.search", "memory.search":
                return "search"
            case "web.fetch", "memory.read", "todo.read", "tasks.list", "tasks.get",
                 "feature.list", "feature.validate":
                return "read"
            case "memory.write", "todo.write", "tasks.update", "feature.scaffold",
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
        XcodeToolIntegration.presentationKind(for: rawName)
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
            if toolName.hasPrefix("agent.") || toolName.hasPrefix("tasks.") {
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
            if XcodeToolIntegration.isToolName(toolName) {
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

        // Compact rendering for delegation tools: surface the most meaningful
        // argument (the sent message, the created agent's identity, or the
        // targeted agent id) instead of the generic key-based fallback below.
        if let agentTarget = agentDisplayTarget(for: toolCall) {
            return agentTarget
        }

        return stringArguments(
            from: toolCall.argumentsObject,
            keys: displayTargetStringArgumentKeys
        ).first
    }

    // MARK: - Agent tool targets

    /// Scalar identifier keys for a delegated agent (recipient of a message or
    /// the target of get/wait/close). Ordered to mirror the runtime lookup in
    /// `DirectSubAgentRuntime.requestedAgentIdentifiers`: id aliases are tried
    /// before `name`/`agent`.
    private static let agentIdentifierScalarKeys = [
        "id",
        "agentID",
        "agent_id",
        "taskID",
        "task_id",
        "name",
        "agent"
    ]

    /// Array identifier keys for multi-recipient forms (`agent.get`,
    /// `agent.wait`, `agent.message`). Mirrors
    /// `DirectSubAgentRuntime.requestedAgentIdentifiers`.
    private static let agentIdentifierArrayKeys = [
        "ids",
        "agentIDs",
        "agent_ids",
        "names"
    ]

    /// Message body keys for `agent.message`, in descending preference
    /// (matches `DirectSubAgentRuntime.messageAgents`).
    private static let agentMessageKeys = ["message", "prompt", "input"]

    /// Name keys for a single `agent.create` payload (matches the runtime
    /// `name` field in `requestedAgentPayload`).
    private static let agentNameKeys = ["name", "title"]

    /// Profile/agent reference keys for a single `agent.create` payload, used
    /// when no explicit name is present. Ordered to mirror the runtime
    /// `profileReference` field, where `agent` is preferred before `profile`.
    private static let agentProfileReferenceKeys = [
        "agent",
        "agentName",
        "agent_name",
        "agentID",
        "agent_id",
        "profile",
        "profileName",
        "profile_name"
    ]

    /// Prompt/instruction keys for `agent.create` (matches the runtime
    /// `prompt` field in `requestedAgentPayload`).
    private static let agentPromptKeys = ["prompt", "message", "initialPrompt", "initial_prompt"]

    /// The sole significant parameter for `agent.list`.
    private static let agentListStatusKeys = ["status"]

    /// Returns the compact-rendering target for `agent.*` tool calls, or `nil`
    /// when the tool is not a delegation tool. Width fitting and whitespace
    /// collapsing are handled downstream by `compactToolInlineTarget` and
    /// `fitDisplayWidth`, so values are returned verbatim.
    private static func agentDisplayTarget(for toolCall: DirectAgentToolCall) -> String? {
        let arguments = toolCall.argumentsObject
        switch toolCall.name {
        case "agent.message":
            return agentMessageTarget(from: arguments)
        case "agent.create":
            return agentCreateTarget(from: arguments)
        case "agent.list":
            // `agent.list` carries only an optional `status` filter; when it is
            // absent there is nothing significant to show (single-line form).
            return stringArgument(arguments, keys: agentListStatusKeys)
        case "agent.get", "agent.wait", "agent.close":
            return agentIdentifierSummary(from: arguments)
        default:
            return nil
        }
    }

    /// Renders the recipient for `agent.message`, honoring both the scalar
    /// identifier forms and the multi-recipient `ids`/`names` arrays. The
    /// resulting prefix is applied to the message body so an `ids` form still
    /// reads "worker, builder: fix the tests".
    private static func agentMessageTarget(from arguments: [String: Any]) -> String? {
        let recipient = agentIdentifierSummary(from: arguments)
        let message = stringArgument(arguments, keys: agentMessageKeys)
        switch (recipient, message) {
        case let (recipient?, message?):
            return "\(recipient): \(message)"
        case (_, let message?):
            return message
        case (let recipient?, nil):
            return recipient
        default:
            return nil
        }
    }

    private static func agentCreateTarget(from arguments: [String: Any]) -> String? {
        if let batchTarget = agentBatchCreateTarget(from: arguments) {
            return batchTarget
        }
        // Prefer an explicit name, then fall back to the agent/profile
        // reference (agent before profile, matching the runtime).
        let name = stringArgument(arguments, keys: agentNameKeys)
            ?? stringArgument(arguments, keys: agentProfileReferenceKeys)
        let prompt = stringArgument(arguments, keys: agentPromptKeys)
        switch (name, prompt) {
        case let (name?, prompt?):
            return "\(name) \(prompt)"
        case (let name?, nil):
            return name
        case (nil, let prompt?):
            return prompt
        default:
            return nil
        }
    }

    /// Summarizes the batch `agents`/`items` form of `agent.create`. Prefers
    /// the joined agent names; falls back to an "N agents" count when no entry
    /// exposes a name.
    private static func agentBatchCreateTarget(from arguments: [String: Any]) -> String? {
        guard let entries = dictionaryArrayArgument(from: arguments, keys: ["agents", "items"]),
              !entries.isEmpty else {
            return nil
        }
        // For each batch element, apply the same precedence as the single form:
        // an explicit name, then a fall back to the agent/profile reference
        // (agent before profile, matching the runtime).
        let names = entries.compactMap { entry in
            stringArgument(entry, keys: agentNameKeys)
                ?? stringArgument(entry, keys: agentProfileReferenceKeys)
        }
        switch names.count {
        case 0:
            return "\(entries.count) agents"
        case 1:
            return names.first
        default:
            return names.joined(separator: ", ")
        }
    }

    /// Returns a compact identifier summary for get/wait/close/message targets,
    /// mirroring `DirectSubAgentRuntime.requestedAgentIdentifiers`: the scalar
    /// identifier (id aliases before name) is combined with the multi-recipient
    /// array forms (`ids`/`agentIDs`/`agent_ids`/`names`), scalar first, then
    /// deduplicated (trimmed, order-preserving) before summarizing.
    private static func agentIdentifierSummary(from arguments: [String: Any]) -> String? {
        var identifiers: [String] = []
        if let scalar = stringArgument(arguments, keys: agentIdentifierScalarKeys) {
            identifiers.append(scalar)
        }
        identifiers.append(
            contentsOf: stringArrayArgument(from: arguments, keys: agentIdentifierArrayKeys)
        )
        let deduplicated = dedupeIdentifiers(identifiers)
        return identifierListSummary(deduplicated)
    }

    /// Trims each identifier and drops empty/duplicate values, preserving the
    /// first-seen order (matches the runtime dedupe).
    private static func dedupeIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }

    private static func identifierListSummary(_ identifiers: [String]) -> String? {
        switch identifiers.count {
        case 0:
            return nil
        case 1:
            return identifiers.first
        default:
            return identifiers.joined(separator: ", ")
        }
    }

    /// Extracts an array of dictionaries from any of `keys`, accepting both
    /// `JSONValue` and native Swift payloads (matching the heterogeneous ways
    /// `DirectAgentToolCall.argumentsObject` is populated).
    private static func dictionaryArrayArgument(
        from arguments: [String: Any],
        keys: [String]
    ) -> [[String: Any]]? {
        for key in keys {
            let entries = dictionaryArray(from: arguments[key])
            if !entries.isEmpty {
                return entries
            }
        }
        return nil
    }

    /// Reads an array of dictionaries from a raw value, handling a wrapped
    /// `JSONValue.array`, a `[JSONValue]`, and native `[Any]` payloads.
    private static func dictionaryArray(from rawValue: Any?) -> [[String: Any]] {
        // A batch wrapped directly in `JSONValue.array(...)` (accepted by the
        // runtime via `requestedAgentPayloads`) must be unwrapped first.
        if let jsonValue = rawValue as? JSONValue,
           let array = jsonValue.arrayValue {
            return array.compactMap(dictionaryEntry(from:))
        }
        if let jsonValues = rawValue as? [JSONValue] {
            return jsonValues.compactMap(dictionaryEntry(from:))
        }
        if let anyValues = rawValue as? [Any] {
            return anyValues.compactMap(dictionaryEntry(from:))
        }
        return []
    }

    private static func dictionaryEntry(from value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        if let jsonValue = value as? JSONValue,
           let object = jsonValue.objectValue {
            // Normalize nested `JSONValue` payloads to native values so the
            // shared `stringArgument` helper reads them uniformly.
            return object.mapValues(\.jsonObject)
        }
        return nil
    }

    /// Extracts a string list from the first of `keys` that yields values,
    /// handling `JSONValue.array`, `[JSONValue]`, `[String]`, and `[Any]`
    /// payloads. Non-string entries are coerced via `flexibleStringValue`.
    private static func stringArrayArgument(
        from arguments: [String: Any],
        keys: [String]
    ) -> [String] {
        for key in keys {
            let values = stringList(from: arguments[key])
            if !values.isEmpty {
                return values
            }
        }
        return []
    }

    private static func stringList(from rawValue: Any?) -> [String] {
        if let jsonValue = rawValue as? JSONValue {
            return (jsonValue.arrayValue ?? [])
                .compactMap { $0.flexibleStringValue?.nilIfBlank }
        }
        if let jsonValues = rawValue as? [JSONValue] {
            return jsonValues.compactMap { $0.flexibleStringValue?.nilIfBlank }
        }
        if let strings = rawValue as? [String] {
            return strings.compactMap { $0.nilIfBlank }
        }
        if let anyValues = rawValue as? [Any] {
            return anyValues.compactMap { ($0 as? String)?.nilIfBlank }
        }
        return []
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
