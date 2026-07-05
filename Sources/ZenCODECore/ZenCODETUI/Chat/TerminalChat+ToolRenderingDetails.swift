//
//  TerminalChat+ToolRenderingDetails.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    static func detailedToolCallStartedLines(
        for toolCall: DirectAgentToolCall,
        level: ToolOutputDetailLevel = .medium
    ) -> [String] {
        var lines = detailedToolBaseLines(for: toolCall, level: level)
        if isFileMutationTool(toolCall.name) {
            lines.append("change: pending")
        }
        lines.append("status: ⏳")
        return lines
    }

    static func detailedToolCallCompletedLines(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        level: ToolOutputDetailLevel = .medium
    ) -> [String] {
        var lines = detailedToolBaseLines(for: toolCall, level: level)

        if result.isFailure {
            lines.append("error:")
            lines.append(contentsOf: indentedSnippet(result.output, level: level))
            lines.append("status: ⚠️")
            return lines
        }

        let changeLines = appliedChangeDetailLines(for: toolCall, level: level)
        if !changeLines.isEmpty {
            lines.append(contentsOf: changeLines)
        } else if let summary = compactSummaryLine(result.summary) {
            lines.append("summary: \(summary)")
        }
        lines.append("status: ✅")
        return lines
    }

    static func detailedToolBaseLines(
        for toolCall: DirectAgentToolCall,
        level: ToolOutputDetailLevel = .medium
    ) -> [String] {
        let title = ZenCODEACPBridge.toolTitle(for: toolCall)
        let kind = ZenCODEACPBridge.toolKind(for: toolCall.name)
        let icon = ZenCODEACPBridge.toolIcon(for: toolCall.name)
        var lines = [
            "\(icon)  \(title)",
            "kind: \(kind)"
        ]
        lines.append(contentsOf: toolLocationLines(for: toolCall))
        if level == .detail {
            lines.append(contentsOf: parameterLines(for: toolCall, level: level))
        }
        return lines
    }

    /// Renders the full call parameters as pretty-printed JSON for the
    /// `detail` level, keeping the formatting and applying the wider limits.
    static func parameterLines(
        for toolCall: DirectAgentToolCall,
        level: ToolOutputDetailLevel
    ) -> [String] {
        guard !toolCall.argumentsObject.isEmpty else {
            return []
        }
        let pretty = JSONValue(jsonObject: toolCall.argumentsObject).prettyPrinted()
        guard pretty != "{}" else {
            return []
        }
        var lines = ["parameters:"]
        let formatted = formattedParameterSnippet(for: toolCall.argumentsObject)
        if formatted.preservesIndentation {
            lines.append(contentsOf: indentedSnippetPreservingIndentation(formatted.text, level: level))
        } else {
            lines.append(contentsOf: indentedSnippet(formatted.text, level: level))
        }
        return lines
    }

    static func formattedParameterSnippet(
        for arguments: [String: Any]
    ) -> (text: String, preservesIndentation: Bool) {
        let entries = arguments
            .map { (key: $0.key, value: JSONValue(jsonObject: $0.value)) }
            .sorted { $0.key < $1.key }
        guard entries.contains(where: { shouldRenderParameterAsMultilineString($0.value) }) else {
            return (JSONValue(jsonObject: arguments).prettyPrinted(), false)
        }

        var lines = ["{"]
        for (index, entry) in entries.enumerated() {
            let suffix = index == entries.count - 1 ? "" : ","
            let key = JSONValue.string(entry.key).compactString(sortedKeys: true)
            let valueLines = formattedParameterValueLines(entry.value)
            for (lineIndex, valueLine) in valueLines.enumerated() {
                let lineSuffix = lineIndex == valueLines.count - 1 ? suffix : ""
                if lineIndex == 0 {
                    lines.append("  \(key): \(valueLine)\(lineSuffix)")
                } else {
                    lines.append("  \(valueLine)\(lineSuffix)")
                }
            }
        }
        lines.append("}")
        return (lines.joined(separator: "\n"), true)
    }

    static func shouldRenderParameterAsMultilineString(_ value: JSONValue) -> Bool {
        guard case let .string(text) = value else {
            return false
        }
        return text.contains("\n") && !text.contains("\"\"\"")
    }

    static func formattedParameterValueLines(_ value: JSONValue) -> [String] {
        if case let .string(text) = value,
           shouldRenderParameterAsMultilineString(value) {
            let contentLines = text
                .trimmingCharacters(in: .newlines)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            return ["\"\"\""] + contentLines + ["\"\"\""]
        }
        return value
            .prettyPrinted()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func appliedChangeDetailLines(
        for toolCall: DirectAgentToolCall,
        level: ToolOutputDetailLevel = .medium
    ) -> [String] {
        let arguments = toolCall.argumentsObject
        switch normalizedMutationToolName(toolCall.name) {
        case "local.writeFile", "XcodeWrite":
            var lines = ["change: write \(targetPath(arguments) ?? "file")"]
            if let content = stringArgument(arguments, keys: ["content", "text"]) {
                lines.append("content:")
                lines.append(contentsOf: indentedSnippet(content, level: level))
            }
            return lines
        case "local.append":
            var lines = ["change: append \(targetPath(arguments) ?? "file")"]
            if let content = stringArgument(arguments, keys: ["content", "text"]) {
                lines.append("appended:")
                lines.append(contentsOf: indentedSnippet(content, level: level))
            }
            return lines
        case "local.replace", "local.editFile", "XcodeUpdate":
            var lines = ["change: replace \(targetPath(arguments) ?? "file")"]
            if boolArgument(arguments, keys: ["replaceAll", "replace_all"]) == true {
                lines.append("mode: replace all")
            }
            if let oldString = stringArgument(arguments, keys: ["oldString", "old_string"]) {
                lines.append("old:")
                lines.append(contentsOf: indentedSnippet(oldString, level: level))
            }
            if let newString = stringArgument(arguments, keys: ["newString", "new_string"]) {
                lines.append("new:")
                lines.append(contentsOf: indentedSnippet(newString, level: level))
            }
            return lines
        case "local.multiEdit":
            return multiEditChangeDetailLines(arguments, level: level)
        case "local.applyPatch":
            let target = ZenCODEACPBridge.patchDisplayTarget(from: arguments) ?? "file"
            var lines = ["change: patch \(target)"]
            if let patch = stringArgument(arguments, keys: ["patch", "diff"]) {
                lines.append("patch:")
                lines.append(contentsOf: indentedSnippet(patch, level: level))
            }
            return lines
        case "local.delete", "XcodeRM":
            return ["change: delete \(targetPath(arguments) ?? "file")"]
        case "local.move", "XcodeMV":
            return [
                "change: move",
                "from: \(stringArgument(arguments, keys: ["sourcePath", "source_path", "from"]) ?? "unknown")",
                "to: \(stringArgument(arguments, keys: ["destinationPath", "destination_path", "to"]) ?? "unknown")"
            ]
        case "local.mkdir":
            return ["change: create directory \(targetPath(arguments) ?? "directory")"]
        default:
            return []
        }
    }

    static func toolLocationLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        ZenCODEACPBridge.toolLocations(for: toolCall).compactMap { location in
            guard let path = location["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return "location: \(path)"
        }
    }

    static func multiEditChangeDetailLines(
        _ arguments: [String: Any],
        level: ToolOutputDetailLevel = .medium
    ) -> [String] {
        let edits = arrayObjectArgument(arguments, keys: ["edits"])
        var lines = [
            "change: edit \(targetPath(arguments) ?? "file") (\(edits.count) edits)"
        ]
        for (index, edit) in edits.prefix(3).enumerated() {
            lines.append("edit \(index + 1):")
            if let oldString = stringArgument(edit, keys: ["oldString", "old_string"]) {
                lines.append("  old:")
                lines.append(contentsOf: indentedSnippet(oldString, indentation: "    ", level: level))
            }
            if let newString = stringArgument(edit, keys: ["newString", "new_string"]) {
                lines.append("  new:")
                lines.append(contentsOf: indentedSnippet(newString, indentation: "    ", level: level))
            }
        }
        if edits.count > 3 {
            lines.append("... \(edits.count - 3) more edits")
        }
        return lines
    }

    static func isFileMutationTool(_ toolName: String) -> Bool {
        switch normalizedMutationToolName(toolName) {
        case "local.writeFile", "local.append", "local.replace",
             "local.editFile", "local.multiEdit", "local.applyPatch",
             "local.delete", "local.move", "local.mkdir",
             "XcodeWrite", "XcodeUpdate", "XcodeRM", "XcodeMV":
            return true
        default:
            return false
        }
    }

    static func normalizedMutationToolName(_ toolName: String) -> String {
        let trimmedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.hasPrefix("xcode.") {
            return String(trimmedName.dropFirst("xcode.".count))
        }
        return trimmedName
    }

    static func targetPath(_ arguments: [String: Any]) -> String? {
        stringArgument(
            arguments,
            keys: [
                "file_path",
                "filePath",
                "file",
                "path",
                "directoryPath",
                "directory_path"
            ]
        )
    }

    static func stringArgument(
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

    static func boolArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            if let value = arguments[key] as? Bool {
                return value
            }
            if let value = arguments[key] as? JSONValue {
                return value.boolValue
            }
        }
        return nil
    }

    static func arrayObjectArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [[String: Any]] {
        for key in keys {
            if let value = arguments[key] as? [[String: Any]] {
                return value
            }
            if let value = arguments[key] as? [Any] {
                return value.compactMap { $0 as? [String: Any] }
            }
            if let value = arguments[key] as? JSONValue,
               case let .array(items) = value {
                return items.compactMap { item in
                    guard case let .object(object) = item else {
                        return nil
                    }
                    return object.mapValues(\.jsonObject)
                }
            }
        }
        return []
    }

    static func compactSummaryLine(_ text: String) -> String? {
        let summary = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .nilIfBlank
        guard let summary else {
            return nil
        }
        if summary.count <= 160 {
            return summary
        }
        return "\(summary.prefix(157))..."
    }

    static func indentedSnippet(
        _ text: String,
        indentation: String = "  ",
        level: ToolOutputDetailLevel = .medium
    ) -> [String] {
        let characterLimit = snippetCharacterLimit(for: level)
        let lineLimit = snippetLineLimit(for: level)
        var snippet = text.trimmingCharacters(in: .newlines)
        if snippet.count > characterLimit {
            snippet = String(snippet.prefix(characterLimit))
        }
        var lines = snippet
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // De-indent: use the minimum leading whitespace of non-empty lines
        // excluding the first as the reference. The first line often loses
        // its original indentation in transit, so using it as reference
        // would prevent de-indentation. Remove that amount from all lines.
        let minIndent = lines.dropFirst()
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { leadingSpaceCount($0) }
            .min() ?? 0
        if minIndent > 0 {
            lines = lines.map { line in
                line.isEmpty ? line : String(line.dropFirst(min(minIndent, leadingSpaceCount(line))))
            }
        }

        let visibleLines = Array(lines.prefix(lineLimit))
        var output = visibleLines.isEmpty
            ? ["\(indentation)<empty>"]
            : visibleLines.map { "\(indentation)\($0)" }
        if lines.count > visibleLines.count || text.count > snippet.count {
            output.append("\(indentation)... truncated")
        }
        return output
    }

    static func indentedSnippetPreservingIndentation(
        _ text: String,
        indentation: String = "  ",
        level: ToolOutputDetailLevel = .medium
    ) -> [String] {
        let characterLimit = snippetCharacterLimit(for: level)
        let lineLimit = snippetLineLimit(for: level)
        var snippet = text.trimmingCharacters(in: .newlines)
        if snippet.count > characterLimit {
            snippet = String(snippet.prefix(characterLimit))
        }
        let lines = snippet
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let visibleLines = Array(lines.prefix(lineLimit))
        var output = visibleLines.isEmpty
            ? ["\(indentation)<empty>"]
            : visibleLines.map { "\(indentation)\($0)" }
        if lines.count > visibleLines.count || text.count > snippet.count {
            output.append("\(indentation)... truncated")
        }
        return output
    }

    static func leadingSpaceCount(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else {
                break
            }
        }
        return count
    }
}
