//
//  TerminalTelegramToolCallFormatter.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Formats a `DirectAgentToolCall` into a concise, safe Telegram progress message.
///
/// The formatter is transport-agnostic: it only inspects the tool name and its
/// `argumentsObject`. It prioritises file paths (converting absolute paths inside
/// the working directory to workspace-relative form), then falls back to a small
/// allowlist of contextual fields for tools that do not operate on files.
/// Sensitive argument fields (file contents, full patches, prompts, old/new
/// text, environment maps) are never serialized. Allowed contextual values
/// (commands, patterns, queries, URLs) are truncated but not redacted; they
/// may contain operational data visible to the Telegram recipient.
enum TerminalTelegramToolCallFormatter {

    // MARK: - Public entry point

    /// Returns a one-or-two line Telegram message for a tool-call start event.
    ///
    /// - Parameters:
    ///   - toolCall: The direct-agent tool call to describe.
    ///   - workingDirectory: The session working directory used to shorten absolute paths.
    /// - Returns: A message whose first line is always `🔧 <tool-name> · <kind>`.
    static func format(
        _ toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) -> String {
        let kind = ToolCallPresentation.toolKind(for: toolCall.name)
        let header = "🔧 \(toolCall.name) · \(kind)"

        guard let detail = detail(for: toolCall, workingDirectory: workingDirectory) else {
            return header
        }
        return "\(header)\n\(detail)"
    }

    // MARK: - Detail extraction

    private static func detail(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) -> String? {
        if let pathDetail = pathDetail(for: toolCall, workingDirectory: workingDirectory) {
            return pathDetail
        }
        return contextualDetail(for: toolCall)
    }

    // MARK: - Path-based detail

    /// Path-like argument keys, ordered from most specific to least specific.
    /// Specific keys (`file_path`, `filePath`, `file`) are tried before the
    /// generic `path` so that a workspace-root `path` does not shadow a
    /// more informative file target.
    private static let pathKeys: [String] = [
        "file_path", "filePath", "file",
        "sourcePath", "source_path", "sourceFilePath", "source_file_path",
        "destinationPath", "destination_path",
        "directoryPath", "directory_path",
        "manifestPath", "manifest_path",
        "path"
    ]

    private static let pathArrayKeys: [String] = [
        "paths", "file_paths", "filePaths"
    ]

    /// Tool-name prefixes for which path-like argument keys are semantically
    /// guaranteed to be filesystem paths. For unknown/custom tools, path
    /// extraction is skipped to avoid leaking arbitrary values.
    private static let pathOrientedPrefixes: [String] = [
        "local.", "text.", "git.", "swift.", "search."
    ]

    private static func isPathOrientedTool(_ name: String) -> Bool {
        pathOrientedPrefixes.contains { name.hasPrefix($0) }
    }

    private static func pathDetail(
        for toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) -> String? {
        let name = toolCall.name
        let args = toolCall.argumentsObject

        // Move: show source → destination.
        if name == "local.move" {
            let source = stringArgument(args, keys: ["sourcePath", "source_path"])
            let destination = stringArgument(args, keys: ["destinationPath", "destination_path"])
            if let source, let destination {
                return formatMoveDetail(
                    source: source,
                    destination: destination,
                    workingDirectory: workingDirectory
                )
            }
        }

        // readFiles: show first file + remaining count.
        if name == "local.readFiles" {
            let paths = pathArrayArgument(args, keys: pathArrayKeys)
            if !paths.isEmpty {
                return formatFileListDetail(paths: paths, workingDirectory: workingDirectory)
            }
        }

        // applyPatch: extract file names from the patch header.
        if name == "local.applyPatch" {
            let targets = patchPathTargets(from: args)
            if !targets.isEmpty {
                return formatFileListDetail(paths: targets, workingDirectory: workingDirectory)
            }
        }

        // Single-path tools: readFile, writeFile, editFile, mkdir, delete, etc.
        // Only apply path extraction to known path-oriented tools.
        guard isPathOrientedTool(name) else {
            return nil
        }

        // Iterate over candidates and return the first that produces a
        // non-nil formatted result (skips uninformative "." paths).
        for key in pathKeys {
            if let candidate = stringArgument(args, keys: [key]),
               let formatted = formatSinglePath(candidate, workingDirectory: workingDirectory) {
                return formatted
            }
        }

        return nil
    }

    // MARK: - Contextual (non-path) detail

    /// Returns tool-specific contextual fields (label + argument keys to try).
    /// Fields are ordered by relevance; at most two are included in the output.
    private static func contextualFields(
        for toolName: String
    ) -> [(label: String, keys: [String])] {
        if toolName.hasPrefix("agent.") {
            return [("agent", ["name", "agent", "id", "task_id", "taskID"])]
        }
        if toolName.hasPrefix("tasks.") {
            return [("task", ["id", "taskID", "task_id"]), ("title", ["title", "name"])]
        }
        if toolName.hasPrefix("feature.") {
            return [("feature", ["id", "featureID", "feature_id", "name"])]
        }
        switch toolName {
        case "local.exec":
            // Show only the first token (executable/subcommand) to limit
            // exposure of secrets that may appear in the full command string.
            return [("command", ["command"])]
        case "web.search":
            return [("query", ["query"])]
        case "web.fetch":
            return [("url", ["url", "endpointURL", "endpoint_url"])]
        case "search.grep", "search.locate":
            return [("pattern", ["pattern"])]
        case "search.glob":
            return [("pattern", ["pattern"]), ("glob", ["glob"])]
        case "git.switch", "git.push", "git.fetch", "git.pull":
            return [("branch", ["branch"])]
        case "git.show":
            return [("revision", ["revision", "rev", "commit"])]
        case "git.diff":
            return [("revision", ["base", "baseRevision", "base_revision"])]
        case "git.stash":
            return [("action", ["action"])]
        case "git.grep":
            return [("pattern", ["pattern"])]
        case "swift.build", "swift.test":
            return [("target", ["target"]), ("filter", ["filter"]), ("product", ["product"])]
        case "swift.run":
            return [("executable", ["executable"]), ("product", ["product"])]
        case "swift.package":
            return [("action", ["action"])]
        case "memory.search":
            return [("query", ["query"])]
        case "memory.write":
            return [("title", ["title"])]
        case "todo.write":
            return [("title", ["title"]), ("mode", ["mode"])]
        default:
            return []
        }
    }

    private static func contextualDetail(for toolCall: DirectAgentToolCall) -> String? {
        let args = toolCall.argumentsObject
        let fields = contextualFields(for: toolCall.name)

        // Build an ordered list of (label, value) pairs from the allowlist,
        // stopping once we have at most two concise fields.
        var pairs: [(label: String, value: String)] = []
        for entry in fields {
            guard pairs.count < 2 else { break }
            if let value = stringArgument(args, keys: entry.keys) {
                // For local.exec, show only the first token to limit secret exposure.
                let displayValue = toolCall.name == "local.exec"
                    ? Self.firstToken(of: value)
                    : value
                let truncated = Self.truncatedValue(displayValue, limit: 80)
                pairs.append((entry.label, truncated))
            }
        }

        guard !pairs.isEmpty else {
            return nil
        }

        return pairs.map { "\($0.label): \($0.value)" }.joined(separator: " · ")
    }

    // MARK: - Formatting helpers

    private static func formatSinglePath(_ path: String, workingDirectory: URL) -> String? {
        let relative = relativePath(path, workingDirectory: workingDirectory)
        // Skip the working-directory root itself — it is not informative.
        guard relative != "." else {
            return nil
        }
        return Self.truncatedValue(relative, limit: 120)
    }

    private static func formatMoveDetail(
        source: String,
        destination: String,
        workingDirectory: URL
    ) -> String {
        let src = Self.truncatedValue(relativePath(source, workingDirectory: workingDirectory), limit: 60)
        let dst = Self.truncatedValue(relativePath(destination, workingDirectory: workingDirectory), limit: 60)
        return "\(src) → \(dst)"
    }

    private static func formatFileListDetail(paths: [String], workingDirectory: URL) -> String? {
        // Find the first informative path (skip "." which is the working directory root).
        let informativePaths = paths.compactMap { path -> String? in
            let relative = relativePath(path, workingDirectory: workingDirectory)
            return relative == "." ? nil : relative
        }

        guard !informativePaths.isEmpty else {
            return nil
        }

        guard informativePaths.count > 1 else {
            return Self.truncatedValue(informativePaths[0], limit: 120)
        }

        let first = Self.truncatedValue(informativePaths[0], limit: 80)
        return "\(first) (+\(informativePaths.count - 1) more)"
    }

    // MARK: - Path relativisation

    /// Converts an absolute path inside the working directory to a workspace-relative path.
    /// Paths outside the working directory are kept as-is (but never reduced to basename).
    private static func relativePath(_ path: String, workingDirectory: URL) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }

        // Already relative — return as-is.
        guard trimmed.hasPrefix("/") else {
            return trimmed
        }

        let fileURL = URL(fileURLWithPath: trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let workDir = workingDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()

        // If the path is inside the working directory, strip the prefix.
        let workDirPath = workDir.path
        let filePath = fileURL.path

        if filePath == workDirPath {
            return "."
        }

        // Handle working directory root "/" specially.
        if workDirPath == "/" {
            // Strip the leading "/" to make the path relative.
            return String(filePath.dropFirst())
        }

        if filePath.hasPrefix(workDirPath + "/") {
            return String(filePath.dropFirst(workDirPath.count + 1))
        }

        // Outside the working directory — keep the absolute path.
        return filePath
    }

    // MARK: - Patch extraction

    /// Extracts file paths from `+++`/`---` headers and `*** Add/Update/Delete File:` markers.
    private static func patchPathTargets(from arguments: [String: Any]) -> [String] {
        guard let rawPatch = stringArgument(arguments, keys: ["patch", "diff"]) else {
            return []
        }

        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ value: String, stripGitPrefix: Bool) {
            let normalized = normalizedPatchPath(value, stripGitPrefix: stripGitPrefix)
            guard let normalized, seen.insert(normalized).inserted else {
                return
            }
            candidates.append(normalized)
        }

        for rawLine in rawPatch.components(separatedBy: "\n") {
            if let value = patchSectionValue(rawLine, prefix: "*** Add File: ")
                ?? patchSectionValue(rawLine, prefix: "*** Update File: ")
                ?? patchSectionValue(rawLine, prefix: "*** Delete File: ") {
                // *** Add/Update/Delete File: markers use literal paths — do not strip a/ b/ prefixes.
                append(value, stripGitPrefix: false)
            } else if rawLine.hasPrefix("+++ ") {
                // +++ and --- headers use git diff convention — strip a/ b/ prefixes.
                append(String(rawLine.dropFirst(4)), stripGitPrefix: true)
            } else if rawLine.hasPrefix("--- ") {
                append(String(rawLine.dropFirst(4)), stripGitPrefix: true)
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

    private static func normalizedPatchPath(_ rawValue: String, stripGitPrefix: Bool) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "/dev/null" else {
            return nil
        }
        if stripGitPrefix, (value.hasPrefix("a/") || value.hasPrefix("b/")) {
            value = String(value.dropFirst(2))
        }
        guard !value.isEmpty, value != "/dev/null" else {
            return nil
        }
        return value
    }

    // MARK: - Argument access

    private static func stringArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = arguments[key] as? String,
               let normalized = value.nilIfBlank {
                return normalized
            }
            // Some tool runtimes store arguments as JSONValue rather than plain String.
            if let value = arguments[key] as? JSONValue,
               let normalized = value.stringValue?.nilIfBlank {
                return normalized
            }
        }
        return nil
    }

    private static func pathArrayArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in keys {
            let paths: [String]
            if let rawPaths = arguments[key] as? [String] {
                paths = rawPaths
            } else if let rawValues = arguments[key] as? [Any] {
                paths = rawValues.compactMap { ($0 as? String) }
            } else if let jsonValue = arguments[key] as? JSONValue,
                      case let .array(items) = jsonValue {
                paths = items.compactMap { $0.stringValue }
            } else {
                continue
            }
            for path in paths {
                if let normalized = path.nilIfBlank {
                    let standard = URL(fileURLWithPath: normalized)
                        .standardizedFileURL
                        .path
                    if seen.insert(standard).inserted {
                        result.append(normalized)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Normalisation and truncation

    /// Collapses whitespace/newlines into single spaces and truncates to `limit` characters.
    private static func truncatedValue(_ value: String, limit: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard singleLine.count > limit else {
            return singleLine
        }
        return String(singleLine.prefix(limit - 3)) + "..."
    }

    /// Returns the first whitespace-separated token of a value, to limit
    /// exposure of sensitive data in command strings.
    private static func firstToken(of value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSpace = singleLine.firstIndex(of: " ") else {
            return singleLine
        }
        return String(singleLine[..<firstSpace])
    }
}
