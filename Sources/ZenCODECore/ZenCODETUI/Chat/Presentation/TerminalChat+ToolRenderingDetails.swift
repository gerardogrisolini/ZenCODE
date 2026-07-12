//
//  TerminalChat+ToolRenderingDetails.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    static func detailedToolCallStartedLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        var lines = detailedToolBaseLines(for: toolCall)
        if isFileMutationTool(toolCall.name) {
            lines.append("change: pending")
        }
        lines.append("status: ⏳")
        return lines
    }

    static func detailedToolCallCompletedLines(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> [String] {
        var lines = detailedToolBaseLines(for: toolCall)

        if result.isFailure {
            lines.append("error:")
            lines.append(contentsOf: indentedSnippet(result.output))
            lines.append("status: ⚠️")
            return lines
        }

        let changeLines = appliedChangeDetailLines(for: toolCall)
        if !changeLines.isEmpty {
            lines.append(contentsOf: changeLines)
        } else if let summary = expandedToolSummary(for: toolCall, result: result) {
            lines.append("summary: \(summary)")
        }
        lines.append("status: ✅")
        return lines
    }

    static func detailedToolBaseLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        let title = ToolCallPresentation.toolTitle(for: toolCall)
        let kind = ToolCallPresentation.toolKind(for: toolCall.name)
        let icon = ToolCallPresentation.toolIcon(for: toolCall.name)
        var lines = [
            "\(icon)  \(title)",
            "kind: \(kind)"
        ]
        lines.append(contentsOf: toolLocationLines(for: toolCall))
        if !shouldHideParameterLines(for: toolCall.name) {
            lines.append(contentsOf: parameterLines(for: toolCall))
        }
        return lines
    }

    /// Edit tools already render their old/new strings in the change detail
    /// lines, so repeating the raw parameters would only crowd out the diff.
    static func shouldHideParameterLines(for toolName: String) -> Bool {
        switch normalizedMutationToolName(toolName) {
        case "local.editFile", "local.multiEdit":
            return true
        default:
            return false
        }
    }

    /// Renders the full call parameters as pretty-printed JSON for the
    /// `expanded` level, keeping the formatting and the wide limits.
    static func parameterLines(
        for toolCall: DirectAgentToolCall
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
            lines.append(contentsOf: indentedSnippetPreservingIndentation(formatted.text))
        } else {
            lines.append(contentsOf: indentedSnippet(formatted.text))
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
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        let arguments = toolCall.argumentsObject
        switch normalizedMutationToolName(toolCall.name) {
        case "local.writeFile", "XcodeWrite":
            var lines = ["change: write \(targetPath(arguments) ?? "file")"]
            if let content = stringArgument(arguments, keys: ["content", "text"]) {
                lines.append("content:")
                lines.append(contentsOf: indentedSnippet(content))
            }
            return lines
        case "local.append":
            var lines = ["change: append \(targetPath(arguments) ?? "file")"]
            if let content = stringArgument(arguments, keys: ["content", "text"]) {
                lines.append("appended:")
                lines.append(contentsOf: indentedSnippet(content))
            }
            return lines
        case "local.replace", "local.editFile", "XcodeUpdate":
            var lines = ["change: replace \(targetPath(arguments) ?? "file")"]
            if boolArgument(arguments, keys: ["replaceAll", "replace_all"]) == true {
                lines.append("mode: replace all")
            }
            if let oldString = stringArgument(arguments, keys: ["oldString", "old_string"]) {
                lines.append("old:")
                lines.append(contentsOf: indentedSnippet(oldString))
            }
            if let newString = stringArgument(arguments, keys: ["newString", "new_string"]) {
                lines.append("new:")
                lines.append(contentsOf: indentedSnippet(newString))
            }
            return lines
        case "local.multiEdit":
            return multiEditChangeDetailLines(arguments)
        case "local.applyPatch":
            let target = ToolCallPresentation.patchDisplayTarget(from: arguments) ?? "file"
            var lines = ["change: patch \(target)"]
            if let patch = stringArgument(arguments, keys: ["patch", "diff"]) {
                lines.append("patch:")
                lines.append(contentsOf: indentedSnippet(patch))
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
        ToolCallPresentation.toolLocations(for: toolCall).compactMap { location in
            guard let path = location["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return "location: \(path)"
        }
    }

    static func multiEditChangeDetailLines(
        _ arguments: [String: Any]
    ) -> [String] {
        let edits = arrayObjectArgument(arguments, keys: ["edits"])
        var lines = [
            "change: edit \(targetPath(arguments) ?? "file") (\(edits.count) edits)"
        ]
        for (index, edit) in edits.prefix(3).enumerated() {
            lines.append("edit \(index + 1):")
            if let oldString = stringArgument(edit, keys: ["oldString", "old_string"]) {
                lines.append("  old:")
                lines.append(contentsOf: indentedSnippet(oldString, indentation: "    "))
            }
            if let newString = stringArgument(edit, keys: ["newString", "new_string"]) {
                lines.append("  new:")
                lines.append(contentsOf: indentedSnippet(newString, indentation: "    "))
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

    static func expandedToolSummary(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> String? {
        if let lineCount = numberedFileReadLineCount(
            toolName: toolCall.name,
            output: result.output
        ) {
            let noun = lineCount == 1 ? "line" : "lines"
            return "read \(lineCount) \(noun)"
        }
        return compactSummaryLine(result.summary)
    }

    static func numberedFileReadLineCount(
        toolName: String,
        output: String
    ) -> Int? {
        switch toolName {
        case "local.readFile", "local.readFiles", "text.head", "text.tail":
            break
        case let x where x.lowercased().contains("read"):
            break
        default:
            return nil
        }

        return output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count(where: { line in
                guard line.contains("\t") else {
                    return false
                }
                let lineNumber = line.prefix { $0 != "\t" }
                    .trimmingCharacters(in: .whitespaces)
                return !lineNumber.isEmpty && lineNumber.allSatisfy(\.isWholeNumber)
            })
    }

    static func indentedSnippet(
        _ text: String,
        indentation: String = "  "
    ) -> [String] {
        let characterLimit = expandedSnippetCharacterLimit
        let lineLimit = expandedSnippetLineLimit
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
        indentation: String = "  "
    ) -> [String] {
        let characterLimit = expandedSnippetCharacterLimit
        let lineLimit = expandedSnippetLineLimit
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

    /// Deduces the syntax-highlighting language for the tool's code snippets
    /// from the extension of the file the call targets, so written/edited
    /// code is rendered with proper highlighting in the expanded view.
    static func codeLanguageHint(for toolCall: DirectAgentToolCall) -> String? {
        let arguments = toolCall.argumentsObject
        let path = targetPath(arguments)
            ?? ToolCallPresentation.patchDisplayTarget(from: arguments)
        guard let path else {
            return nil
        }
        let fileExtension = (path as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return fileExtension.isEmpty ? nil : fileExtension
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
