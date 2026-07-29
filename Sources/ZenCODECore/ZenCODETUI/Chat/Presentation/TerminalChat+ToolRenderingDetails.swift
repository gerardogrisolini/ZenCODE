//
//  TerminalChat+ToolRenderingDetails.swift
//  ZenCODE
//

import Foundation
import ToolCore

private struct DetailedToolSnippet {
    let lines: [String]
    let isTruncated: Bool
    /// Structural property of the payload: it carried no source line at all.
    /// Emptiness is deliberately *not* encoded as a sentinel line, so a payload
    /// whose literal text happens to be the empty marker stays distinguishable
    /// both in the numbering and in the diff.
    let isEmptyPayload: Bool
}

private struct DetailedToolDiffRow {
    let oldLineIndex: Int?
    let newLineIndex: Int?
}

extension TerminalChat {
    nonisolated static func detailedToolCallStartedLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        detailedToolCallStartedRows(for: toolCall).map(\.plainText)
    }

    nonisolated static func detailedToolCallStartedRows(
        for toolCall: DirectAgentToolCall
    ) -> [DetailedToolRow] {
        var rows = detailedToolBaseRows(for: toolCall)
        rows.append(.text("status: ⏳"))
        return rows
    }

    nonisolated static func detailedToolCallCompletedLines(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        contentWidth: Int? = nil,
        elapsed: Duration? = nil
    ) -> [String] {
        detailedToolCallCompletedRows(
            for: toolCall,
            result: result,
            contentWidth: contentWidth,
            elapsed: elapsed
        )
        .map(\.plainText)
    }

    /// Structured counterpart of `detailedToolCallCompletedLines`. Side-by-side
    /// diff rows keep their two cells in separate fields all the way to the
    /// renderer, so the column boundary is never encoded into — and never
    /// recovered from — the payload text.
    nonisolated static func detailedToolCallCompletedRows(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        contentWidth: Int? = nil,
        elapsed: Duration? = nil
    ) -> [DetailedToolRow] {
        var rows = detailedToolBaseRows(
            for: toolCall,
            result: result,
            contentWidth: contentWidth
        )

        let elapsedText = elapsed.map { toolElapsedTimeText($0) } ?? ""
        // ⚠️ carries a variation selector that most terminals render as a
        // double-width emoji, visually consuming one trailing space. Use an
        // extra separator so the icon stays separated from the elapsed time.
        let warningStatus = elapsedText.isEmpty
            ? "status: ⚠️"
            : "status: ⚠️  \(elapsedText)"
        let successStatus = elapsedText.isEmpty
            ? "status: ✅"
            : "status: ✅ \(elapsedText)"

        if result.isFailure {
            rows.append(.text("error:"))
            rows.append(contentsOf: indentedSnippet(result.output).map(DetailedToolRow.text))
            rows.append(.text(warningStatus))
            return rows
        }

        rows.append(.text(successStatus))
        return rows
    }

    nonisolated static func detailedToolBaseLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        detailedToolBaseRows(for: toolCall).map(\.plainText)
    }

    nonisolated static func detailedToolBaseRows(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult? = nil,
        contentWidth: Int? = nil
    ) -> [DetailedToolRow] {
        semanticToolRows(
            for: toolCall,
            result: result,
            contentWidth: contentWidth
        )
    }

    /// Converts the core's unstyled semantic presentation into the existing TUI
    /// row primitives. Every label/value is still sanitized here; definitions
    /// from feature processes and MCP servers are untrusted metadata.
    nonisolated static func semanticToolRows(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult?,
        contentWidth: Int?
    ) -> [DetailedToolRow] {
        let presentation = ToolCallPresentation.resolved(
            for: toolCall,
            result: result,
            mode: .expanded
        )
        let icon = ToolCallPresentation.toolIcon(for: toolCall.name)
        let toolName = sanitizedMetadataText(toolCall.name) ?? "tool"
        var rows: [DetailedToolRow] = [
            .text("\(icon)  \(toolName)"),
            .text("kind: \(presentation.kind.rawValue)")
        ]
        if let action = presentation.action.flatMap(sanitizedMetadataText) {
            rows.append(.text("action: \(action)"))
        }
        if let target = presentation.target.flatMap(sanitizedMetadataText) {
            rows.append(.text("target: \(target)"))
        }
        for item in presentation.metadata {
            guard let label = sanitizedMetadataText(item.label),
                  let value = sanitizedMetadataText(item.value) else {
                continue
            }
            rows.append(.text("\(label): \(value)"))
        }
        for element in presentation.elements {
            rows.append(
                contentsOf: semanticElementRows(
                    element,
                    contentWidth: contentWidth,
                    preservesSourceLineNumbers: presentation.kind == .read
                )
            )
        }
        return rows
    }

    nonisolated static func semanticElementRows(
        _ element: ToolPresentationElement,
        contentWidth: Int?,
        preservesSourceLineNumbers: Bool = false
    ) -> [DetailedToolRow] {
        switch element {
        case let .parameters(label, value):
            return semanticParameterRows(label: label, value: value)
        case let .code(label, content, _):
            var rows: [DetailedToolRow] = []
            if let label = label.flatMap(sanitizedMetadataText) {
                rows.append(.text("\(label):"))
            }
            rows.append(contentsOf: preservesSourceLineNumbers
                ? preservedLineNumberCodeSnippetRows(content)
                : numberedCodeSnippetRows(content))
            return rows
        case let .diff(label, old, new, _):
            var rows: [DetailedToolRow] = []
            if let label = label.flatMap(sanitizedMetadataText) {
                rows.append(.text("\(label):"))
            }
            rows.append(
                contentsOf: numberedDiffSnippetRows(
                    old: old,
                    new: new,
                    contentWidth: contentWidth
                )
            )
            return rows
        case let .list(label, items):
            var rows: [DetailedToolRow] = []
            if let label = label.flatMap(sanitizedMetadataText) {
                rows.append(.text("\(label):"))
            }
            for (index, item) in items.enumerated() {
                let rendered = item.prettyPrinted()
                let lines = indentedSnippetPreservingIndentation(rendered)
                if lines.count == 1 {
                    rows.append(.parameter("  \(index + 1). \(lines[0].dropFirst(2))"))
                } else {
                    rows.append(.parameter("  \(index + 1)."))
                    rows.append(contentsOf: lines.map(DetailedToolRow.parameter))
                }
            }
            return rows
        case let .summary(label, text):
            guard let summary = compactSummaryLine(text) else {
                return []
            }
            let label = label.flatMap(sanitizedMetadataText) ?? "summary"
            guard let safeSummary = sanitizedMetadataText(summary) else {
                return []
            }
            return [.text("\(label): \(safeSummary)")]
        }
    }

    nonisolated static func semanticParameterRows(
        label: String?,
        value: JSONValue
    ) -> [DetailedToolRow] {
        let label = label.flatMap(sanitizedMetadataText) ?? "parameters"
        let formatted: (text: String, preservesIndentation: Bool)
        if case let .object(object) = value {
            formatted = formattedParameterSnippet(
                for: object.mapValues(\.jsonObject)
            )
        } else {
            formatted = (value.prettyPrinted(), true)
        }
        let lines = formatted.preservesIndentation
            ? indentedSnippetPreservingIndentation(formatted.text)
            : indentedSnippet(formatted.text)
        return [.text("\(label):")] + lines.map {
            DetailedToolRow.parameter(terminalSafeSnippetLine($0))
        }
    }

    /// Mutation details render either a numbered source/diff area or structured
    /// metadata rows, so raw JSON parameters would only duplicate those details
    /// without their terminal-safe presentation.
    nonisolated static func shouldHideParameterLines(for toolName: String) -> Bool {
        isFileMutationTool(toolName)
    }

    /// Renders the full call parameters as pretty-printed JSON for the
    /// `expanded` level, keeping the formatting and the wide limits.
    nonisolated static func parameterLines(
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

    /// Keeps parameter payload rows distinct from actual source snippets so the
    /// renderer can use a metadata palette instead of the target file language.
    nonisolated static func parameterRows(
        for toolCall: DirectAgentToolCall
    ) -> [DetailedToolRow] {
        parameterLines(for: toolCall).enumerated().map { index, line in
            index == 0 ? .text(line) : .parameter(line)
        }
    }

    nonisolated static func formattedParameterSnippet(
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

    nonisolated static func shouldRenderParameterAsMultilineString(_ value: JSONValue) -> Bool {
        guard case let .string(text) = value else {
            return false
        }
        return text.contains("\n") && !text.contains("\"\"\"")
    }

    nonisolated static func formattedParameterValueLines(_ value: JSONValue) -> [String] {
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

    nonisolated static func appliedChangeDetailLines(
        for toolCall: DirectAgentToolCall,
        contentWidth: Int? = nil
    ) -> [String] {
        appliedChangeDetailRows(for: toolCall, contentWidth: contentWidth)
            .map(\.plainText)
    }

    nonisolated static func appliedChangeDetailRows(
        for toolCall: DirectAgentToolCall,
        contentWidth: Int? = nil
    ) -> [DetailedToolRow] {
        let arguments = toolCall.argumentsObject
        switch normalizedMutationToolName(toolCall.name) {
        case "local.writeFile", "XcodeWrite":
            var rows: [DetailedToolRow] = [.text("change: write \(targetPath(arguments) ?? "file")")]
            if let content = rawStringArgument(arguments, keys: ["content", "text"]) {
                rows.append(.text("content:"))
                rows.append(contentsOf: numberedCodeSnippetRows(content))
            }
            return rows
        case "local.append":
            var rows: [DetailedToolRow] = [.text("change: append \(targetPath(arguments) ?? "file")")]
            if let content = rawStringArgument(arguments, keys: ["content", "text"]) {
                rows.append(.text("appended:"))
                rows.append(contentsOf: numberedCodeSnippetRows(content))
            }
            return rows
        case "local.replace", "local.editFile", "XcodeUpdate":
            var rows: [DetailedToolRow] = [.text("change: replace \(targetPath(arguments) ?? "file")")]
            if boolArgument(arguments, keys: ["replaceAll", "replace_all"]) == true {
                rows.append(.text("mode: replace all"))
            }
            if let oldString = rawStringArgument(arguments, keys: ["oldString", "old_string"]),
               let newString = rawStringArgument(arguments, keys: ["newString", "new_string"]) {
                rows.append(contentsOf: numberedDiffSnippetRows(
                    old: oldString,
                    new: newString,
                    contentWidth: contentWidth
                ))
            } else if let oldString = rawStringArgument(arguments, keys: ["oldString", "old_string"]) {
                rows.append(.text("old:"))
                rows.append(contentsOf: numberedCodeSnippetRows(oldString))
            } else if let newString = rawStringArgument(arguments, keys: ["newString", "new_string"]) {
                rows.append(.text("new:"))
                rows.append(contentsOf: numberedCodeSnippetRows(newString))
            }
            return rows
        case "local.multiEdit":
            return multiEditChangeDetailRows(arguments, contentWidth: contentWidth)
        case "local.applyPatch":
            let target = patchTargetPath(arguments) ?? "file"
            var rows: [DetailedToolRow] = [.text("change: patch \(target)")]
            if let patch = rawStringArgument(arguments, keys: ["patch", "diff"]) {
                rows.append(.text("patch:"))
                rows.append(contentsOf: numberedCodeSnippetRows(patch))
            }
            return rows
        case "local.delete", "XcodeRM":
            return [.text("change: delete \(targetPath(arguments) ?? "file")")]
        case "local.move", "XcodeMV":
            return [
                .text("change: move"),
                .text("from: \(metadataArgument(arguments, keys: ["sourcePath", "source_path", "from"]) ?? "unknown")"),
                .text("to: \(metadataArgument(arguments, keys: ["destinationPath", "destination_path", "to"]) ?? "unknown")")
            ]
        case "local.mkdir":
            return [.text("change: create directory \(targetPath(arguments) ?? "directory")")]
        default:
            return []
        }
    }

    nonisolated static func toolLocationLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        ToolCallPresentation.toolLocations(for: toolCall).compactMap { location in
            guard let path = location["path"] as? String,
                  let sanitizedPath = sanitizedMetadataText(path) else {
                return nil
            }
            return "location: \(sanitizedPath)"
        }
    }

    nonisolated static func multiEditChangeDetailLines(
        _ arguments: [String: Any],
        contentWidth: Int? = nil
    ) -> [String] {
        multiEditChangeDetailRows(arguments, contentWidth: contentWidth)
            .map(\.plainText)
    }

    nonisolated static func multiEditChangeDetailRows(
        _ arguments: [String: Any],
        contentWidth: Int? = nil
    ) -> [DetailedToolRow] {
        let edits = arrayObjectArgument(arguments, keys: ["edits"])
        var rows: [DetailedToolRow] = [
            .text("change: edit \(targetPath(arguments) ?? "file") (\(edits.count) edits)")
        ]
        for (index, edit) in edits.prefix(3).enumerated() {
            rows.append(.text("edit \(index + 1):"))
            if let oldString = rawStringArgument(edit, keys: ["oldString", "old_string"]),
               let newString = rawStringArgument(edit, keys: ["newString", "new_string"]) {
                rows.append(contentsOf: numberedDiffSnippetRows(
                    old: oldString,
                    new: newString,
                    contentWidth: contentWidth,
                    indentation: "    "
                ))
            } else if let oldString = rawStringArgument(edit, keys: ["oldString", "old_string"]) {
                rows.append(.text("  old:"))
                rows.append(contentsOf: numberedCodeSnippetRows(oldString, indentation: "    "))
            } else if let newString = rawStringArgument(edit, keys: ["newString", "new_string"]) {
                rows.append(.text("  new:"))
                rows.append(contentsOf: numberedCodeSnippetRows(newString, indentation: "    "))
            }
        }
        if edits.count > 3 {
            rows.append(.text("... \(edits.count - 3) more edits"))
        }
        return rows
    }

    nonisolated static func isFileMutationTool(_ toolName: String) -> Bool {
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

    /// Canonical Xcode aliases actually accepted by the runtime router.
    /// `XcodeToolRequestCompatibility` maps only these spellings, so the TUI
    /// must not treat a bare `write`/`update`/`edit`/`rm`/`mv` from an unrelated
    /// MCP server as an Xcode mutation.
    private nonisolated static let xcodeMutationAliases: [String: String] = [
        "xcodewrite": "XcodeWrite",
        "xcode_write": "XcodeWrite",
        "xcode.write": "XcodeWrite",
        "xcodeupdate": "XcodeUpdate",
        "xcode_update": "XcodeUpdate",
        "xcode.update": "XcodeUpdate",
        "xcodeedit": "XcodeUpdate",
        "xcode.edit": "XcodeUpdate",
        "xcoderm": "XcodeRM",
        "xcode_rm": "XcodeRM",
        "xcode.rm": "XcodeRM",
        "xcodemv": "XcodeMV",
        "xcode_mv": "XcodeMV",
        "xcode.mv": "XcodeMV"
    ]

    nonisolated static func normalizedMutationToolName(_ toolName: String) -> String {
        let trimmedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Tool-call events reach the TUI before MCP routing canonicalizes the
        // request, so mirror the router's alias table exactly. Both the public
        // `xcode.` form and the already-unprefixed raw name are resolved,
        // matching `XcodeToolIntegration.normalizedRequest`.
        if let canonicalName = xcodeMutationAliases[trimmedName.lowercased()] {
            return canonicalName
        }
        if trimmedName.hasPrefix("xcode.") {
            let rawName = String(trimmedName.dropFirst("xcode.".count))
            if let canonicalName = xcodeMutationAliases[rawName.lowercased()] {
                return canonicalName
            }
            return rawName
        }
        return trimmedName
    }

    /// Path-shaped metadata. Blank or whitespace-only values must fall through
    /// to the next alias key (and ultimately to the caller's fallback), and
    /// control characters must never reach a rendered metadata row or the
    /// language hint.
    nonisolated static func metadataArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = rawStringArgument(arguments, keys: [key]) else {
                continue
            }
            if let sanitized = sanitizedMetadataText(value) {
                return sanitized
            }
        }
        return nil
    }

    /// Single neutralization point for every caller-controllable value rendered
    /// as metadata: titles, locations, change rows, patch targets and the
    /// language hint. Every control scalar — C0, DEL, C1 and the format
    /// characters that carry bidi/zero-width behavior — becomes a space, so no
    /// payload can emit ESC, CR, LF or a tab into a rendered metadata row.
    /// Returns `nil` for values that are blank once neutralized, so the caller
    /// falls through to the next alias or to its own fallback.
    nonisolated static func sanitizedMetadataText(_ value: String) -> String? {
        // CRLF is one line ending rather than two controls, so it collapses to a
        // single space before the per-scalar neutralization below.
        let lineEndingNormalized = value.replacingOccurrences(of: "\r\n", with: " ")
        var sanitized = ""
        sanitized.reserveCapacity(lineEndingNormalized.count)
        for character in lineEndingNormalized {
            let isControl = character.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar.properties.isBidiControl
                    || scalar.properties.isJoinControl
            }
            sanitized.append(isControl ? " " : character)
        }
        let normalized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// Sanitized patch target. `patchDisplayTarget` derives its value from the
    /// patch body, which is fully caller-controlled, so it must not reach the
    /// change row or the language hint unneutralized.
    nonisolated static func patchTargetPath(_ arguments: [String: Any]) -> String? {
        guard let target = ToolCallPresentation.patchDisplayTarget(from: arguments) else {
            return nil
        }
        return sanitizedMetadataText(target)
    }

    nonisolated static func targetPath(_ arguments: [String: Any]) -> String? {
        metadataArgument(
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

    /// Verbatim payload accessor. Source content is reproduced exactly: empty
    /// strings, whitespace-only edits and trailing newlines are all meaningful
    /// mutation payloads, so nothing is trimmed or skipped here.
    nonisolated static func rawStringArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = arguments[key] as? String {
                return value
            }
            if let value = arguments[key] as? JSONValue,
               let stringValue = value.stringValue {
                return stringValue
            }
        }
        return nil
    }

    nonisolated static func stringArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        rawStringArgument(arguments, keys: keys)
    }

    nonisolated static func boolArgument(
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

    nonisolated static func arrayObjectArgument(
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

    nonisolated static func compactSummaryLine(_ text: String) -> String? {
        let summary = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .nilIfBlank
        guard let summary else {
            return nil
        }
        // Count-based inline truncation (see `truncatedByCount`): the 160 budget
        // is a grapheme-cluster count, matching `truncatedInline` rather than the
        // visible-width `fitDisplayWidth` family.
        return truncatedByCount(summary, limit: 160)
    }

    nonisolated static func expandedToolSummary(
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

    nonisolated static func numberedFileReadLineCount(
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

    nonisolated static func indentedSnippet(
        _ text: String,
        indentation: String = "  "
    ) -> [String] {
        let characterLimit = expandedSnippetCharacterLimit
        let lineLimit = expandedSnippetLineLimit
        var snippet = text.trimmingCharacters(in: .newlines)
        var wasTruncated = false
        if snippet.count > characterLimit {
            snippet = String(snippet.prefix(characterLimit))
            wasTruncated = true
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
            : visibleLines.map { terminalSafeSnippetLine("\(indentation)\($0)") }
        if lines.count > visibleLines.count || wasTruncated {
            output.append("\(indentation)... truncated")
        }
        return output
    }

    nonisolated static func indentedSnippetPreservingIndentation(
        _ text: String,
        indentation: String = "  "
    ) -> [String] {
        let characterLimit = expandedSnippetCharacterLimit
        let lineLimit = expandedSnippetLineLimit
        var snippet = text.trimmingCharacters(in: .newlines)
        var wasTruncated = false
        if snippet.count > characterLimit {
            snippet = String(snippet.prefix(characterLimit))
            wasTruncated = true
        }
        let lines = snippet
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let visibleLines = Array(lines.prefix(lineLimit))
        var output = visibleLines.isEmpty
            ? ["\(indentation)<empty>"]
            : visibleLines.map { terminalSafeSnippetLine("\(indentation)\($0)") }
        if lines.count > visibleLines.count || wasTruncated {
            output.append("\(indentation)... truncated")
        }
        return output
    }

    /// Converts a mutation payload into a bounded sequence of source lines.
    /// Writes and both sides of an edit use this shared basis so clipping and
    /// line numbers stay consistent. It deliberately does not trim or
    /// de-indent source: empty files, trailing newlines and whitespace-only
    /// changes are semantically meaningful mutation payloads.
    private nonisolated static func detailedToolSnippet(_ text: String) -> DetailedToolSnippet {
        var snippet = normalizedTerminalLineEndings(text)
        var wasTruncated = false
        if snippet.count > expandedSnippetCharacterLimit {
            snippet = String(snippet.prefix(expandedSnippetCharacterLimit))
            wasTruncated = true
        }

        // `String.split(..., omittingEmptySubsequences: false)` represents an
        // empty string as one blank element. Keep an actually empty payload
        // distinct from a source line that is intentionally blank.
        let lines = snippet.isEmpty
            ? []
            : snippet
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)

        let visibleLines = Array(lines.prefix(expandedSnippetLineLimit))
        return DetailedToolSnippet(
            lines: visibleLines,
            isTruncated: lines.count > visibleLines.count || wasTruncated,
            isEmptyPayload: visibleLines.isEmpty
        )
    }

    /// Visible marker for a payload that carries no source line. It is rendered
    /// in the line-number gutter position *without* a number, so it can never
    /// coincide with a numbered source line whose literal text is `<empty>`.
    private nonisolated static let detailedToolEmptyPayloadMarker = "<empty>"

    /// Prefixes each created/inserted source line with a stable, right-aligned
    /// local number. The indentation keeps it on the existing highlighted code
    /// area path rather than the metadata-label path.
    nonisolated static func numberedCodeSnippetLines(
        _ text: String,
        indentation: String = "  "
    ) -> [String] {
        numberedCodeSnippetRows(text, indentation: indentation).map(\.plainText)
    }

    /// Prefixes each created/inserted source line with a stable, right-aligned
    /// local number. The indentation keeps it on the existing highlighted code
    /// area path rather than the metadata-label path.
    nonisolated static func numberedCodeSnippetRows(
        _ text: String,
        indentation: String = "  "
    ) -> [DetailedToolRow] {
        let snippet = detailedToolSnippet(text)
        let numberWidth = String(max(1, snippet.lines.count)).count
        var rendered = snippet.lines.enumerated().map { index, line in
            DetailedToolRow.code(DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: paddedLineNumber(index + 1, width: numberWidth),
                content: terminalSafeSnippetLine(line)
            ))
        }
        if snippet.isEmptyPayload {
            // Structural emptiness: no line number is assigned, so this row is
            // distinct from a numbered line whose content is literally the
            // marker text.
            rendered.append(.code(DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: String(repeating: " ", count: numberWidth),
                content: detailedToolEmptyPayloadMarker
            )))
        }
        if snippet.isTruncated {
            rendered.append(.code(DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: String(repeating: " ", count: numberWidth),
                content: "... truncated"
            )))
        }
        return rendered
    }

    /// Renders output from file-read tools, whose wire text already prefixes
    /// source rows with `<real line number>\t`. The prefix is consumed into the
    /// gutter instead of being displayed as a second number in the source cell.
    nonisolated static func preservedLineNumberCodeSnippetRows(
        _ text: String,
        indentation: String = "  "
    ) -> [DetailedToolRow] {
        let snippet = detailedToolSnippet(text)
        let parsedLines = snippet.lines.map { line -> (number: Int?, content: String) in
            guard let tab = line.firstIndex(of: "\t") else {
                return (nil, line)
            }
            let numberText = line[..<tab]
            guard !numberText.isEmpty,
                  numberText.allSatisfy(\.isWholeNumber),
                  let number = Int(numberText) else {
                return (nil, line)
            }
            return (number, String(line[line.index(after: tab)...]))
        }
        let numberWidth = max(
            1,
            parsedLines.compactMap { $0.number }.map { String($0).count }.max() ?? 1
        )
        var rendered = parsedLines.map { line in
            DetailedToolRow.code(DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: line.number.map {
                    paddedLineNumber($0, width: numberWidth)
                } ?? String(repeating: " ", count: numberWidth),
                content: terminalSafeSnippetLine(line.content)
            ))
        }
        if snippet.isEmptyPayload {
            rendered.append(.code(DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: String(repeating: " ", count: numberWidth),
                content: detailedToolEmptyPayloadMarker
            )))
        }
        if snippet.isTruncated {
            rendered.append(.code(DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: String(repeating: " ", count: numberWidth),
                content: "... truncated"
            )))
        }
        return rendered
    }

    /// Minimum useful width for each source cell in a side-by-side expanded
    /// diff. With the standard two-cell indentation and three-cell divider,
    /// this documents a 53-cell content-width threshold (2 + 3 + 24 * 2).
    /// At or below a smaller budget the renderer uses stacked unified `-` / `+`
    /// rows rather than squeezing source code into unusably narrow columns.
    nonisolated static let detailedToolSideBySideDiffMinimumCellWidth = 24

    /// Renders old and new edit payloads side by side when both columns can
    /// retain useful source context. Narrow terminals receive a unified,
    /// stacked `-` / `+` view, which the detailed wrapper safely reflows without
    /// horizontal scrolling.
    nonisolated static func numberedDiffSnippetLines(
        old: String,
        new: String,
        contentWidth: Int?,
        indentation: String = "  "
    ) -> [String] {
        numberedDiffSnippetRows(
            old: old,
            new: new,
            contentWidth: contentWidth,
            indentation: indentation
        )
        .map(\.plainText)
    }

    /// Renders old and new edit payloads side by side when both columns can
    /// retain useful source context. Narrow terminals receive a unified,
    /// stacked `-` / `+` view. Each side-by-side row carries its two cells
    /// separately, so no content sequence can be mistaken for the divider.
    nonisolated static func numberedDiffSnippetRows(
        old: String,
        new: String,
        contentWidth: Int?,
        indentation: String = "  "
    ) -> [DetailedToolRow] {
        let oldSnippet = detailedToolSnippet(old)
        let newSnippet = detailedToolSnippet(new)
        let availableWidth = max(1, contentWidth ?? terminalColumnCount())
        let dividerWidth = displayWidth(DetailedToolDiffCells.divider)
        let columnWidth = max(
            0,
            (availableWidth - displayWidth(indentation) - dividerWidth) / 2
        )

        guard columnWidth >= detailedToolSideBySideDiffMinimumCellWidth else {
            return numberedUnifiedDiffSnippetRows(
                old: oldSnippet,
                new: newSnippet,
                indentation: indentation
            )
        }

        let oldNumberWidth = String(max(1, oldSnippet.lines.count)).count
        let newNumberWidth = String(max(1, newSnippet.lines.count)).count
        var rows: [DetailedToolRow] = [
            .diff(DetailedToolDiffCells(
                indentation: indentation,
                oldCell: paddedToDisplayWidth("old", width: columnWidth),
                newCell: paddedToDisplayWidth("new", width: columnWidth)
            ))
        ]
        if oldSnippet.isEmptyPayload || newSnippet.isEmptyPayload {
            // Structural emptiness never enters the LCS input, so an empty side
            // cannot compare equal to — or be confused with — a source line whose
            // literal text is the marker. It is reported once, unnumbered.
            rows.append(.diff(DetailedToolDiffCells(
                indentation: indentation,
                oldCell: detailedToolEmptyPayloadCell(
                    isEmpty: oldSnippet.isEmptyPayload,
                    numberWidth: oldNumberWidth,
                    width: columnWidth
                ),
                newCell: detailedToolEmptyPayloadCell(
                    isEmpty: newSnippet.isEmptyPayload,
                    numberWidth: newNumberWidth,
                    width: columnWidth
                )
            )))
        }
        for row in detailedToolDiffRows(old: oldSnippet.lines, new: newSnippet.lines) {
            let oldCell = detailedToolDiffCell(
                line: row.oldLineIndex.map { oldSnippet.lines[$0] },
                number: row.oldLineIndex.map { $0 + 1 },
                numberWidth: oldNumberWidth,
                width: columnWidth
            )
            let newCell = detailedToolDiffCell(
                line: row.newLineIndex.map { newSnippet.lines[$0] },
                number: row.newLineIndex.map { $0 + 1 },
                numberWidth: newNumberWidth,
                width: columnWidth
            )
            rows.append(.diff(DetailedToolDiffCells(
                indentation: indentation,
                oldCell: oldCell,
                newCell: newCell
            )))
        }
        if oldSnippet.isTruncated || newSnippet.isTruncated {
            let oldMarker = oldSnippet.isTruncated ? "... truncated" : ""
            let newMarker = newSnippet.isTruncated ? "... truncated" : ""
            rows.append(.diff(DetailedToolDiffCells(
                indentation: indentation,
                oldCell: paddedToDisplayWidth(oldMarker, width: columnWidth),
                newCell: paddedToDisplayWidth(newMarker, width: columnWidth)
            )))
        }
        return rows
    }

    /// Builds the narrow presentation from the same LCS row model as the wide
    /// view. Changed source lines become adjacent `-` / `+` rows; unchanged
    /// lines are emitted once as context. This preserves source numbering and
    /// structural empty/truncation markers without relying on in-band text
    /// sentinels or a side-by-side divider.
    private nonisolated static func numberedUnifiedDiffSnippetRows(
        old: DetailedToolSnippet,
        new: DetailedToolSnippet,
        indentation: String
    ) -> [DetailedToolRow] {
        let numberWidth = String(max(1, old.lines.count, new.lines.count)).count
        let blankLineNumber = String(repeating: " ", count: numberWidth)

        func lineNumber(_ index: Int?) -> String {
            guard let index else {
                return blankLineNumber
            }
            return paddedLineNumber(index + 1, width: numberWidth)
        }

        func unifiedRow(
            marker: String,
            lineIndex: Int?,
            content: String
        ) -> DetailedToolRow {
            .unifiedDiff(DetailedToolUnifiedDiffLine(
                indentation: indentation,
                marker: marker,
                lineNumber: lineNumber(lineIndex),
                content: terminalSafeSnippetLine(content)
            ))
        }

        var rows: [DetailedToolRow] = []
        if old.isEmptyPayload {
            rows.append(unifiedRow(
                marker: "-",
                lineIndex: nil,
                content: detailedToolEmptyPayloadMarker
            ))
        }
        if new.isEmptyPayload {
            rows.append(unifiedRow(
                marker: "+",
                lineIndex: nil,
                content: detailedToolEmptyPayloadMarker
            ))
        }

        for row in detailedToolDiffRows(old: old.lines, new: new.lines) {
            if let oldIndex = row.oldLineIndex,
               let newIndex = row.newLineIndex,
               old.lines[oldIndex] == new.lines[newIndex] {
                rows.append(unifiedRow(
                    marker: " ",
                    lineIndex: newIndex,
                    content: new.lines[newIndex]
                ))
                continue
            }
            if let oldIndex = row.oldLineIndex {
                rows.append(unifiedRow(
                    marker: "-",
                    lineIndex: oldIndex,
                    content: old.lines[oldIndex]
                ))
            }
            if let newIndex = row.newLineIndex {
                rows.append(unifiedRow(
                    marker: "+",
                    lineIndex: newIndex,
                    content: new.lines[newIndex]
                ))
            }
        }

        if old.isTruncated {
            rows.append(unifiedRow(
                marker: "-",
                lineIndex: nil,
                content: "... truncated"
            ))
        }
        if new.isTruncated {
            rows.append(unifiedRow(
                marker: "+",
                lineIndex: nil,
                content: "... truncated"
            ))
        }
        return rows
    }

    /// Uses LCS to retain unchanged lines on the same visual row. Intervening
    /// removals and insertions are paired in order, keeping replacements easy
    /// to compare while preserving blanks for pure additions/removals.
    private nonisolated static func detailedToolDiffRows(
        old: [String],
        new: [String]
    ) -> [DetailedToolDiffRow] {
        var lcs = Array(
            repeating: Array(repeating: 0, count: new.count + 1),
            count: old.count + 1
        )
        if !old.isEmpty, !new.isEmpty {
            for oldIndex in stride(from: old.count - 1, through: 0, by: -1) {
                for newIndex in stride(from: new.count - 1, through: 0, by: -1) {
                    if old[oldIndex] == new[newIndex] {
                        lcs[oldIndex][newIndex] = lcs[oldIndex + 1][newIndex + 1] + 1
                    } else {
                        lcs[oldIndex][newIndex] = max(
                            lcs[oldIndex + 1][newIndex],
                            lcs[oldIndex][newIndex + 1]
                        )
                    }
                }
            }
        }

        var rows: [DetailedToolDiffRow] = []
        var pendingOld: [Int] = []
        var pendingNew: [Int] = []
        func flushPending() {
            let count = max(pendingOld.count, pendingNew.count)
            for index in 0..<count {
                rows.append(DetailedToolDiffRow(
                    oldLineIndex: index < pendingOld.count ? pendingOld[index] : nil,
                    newLineIndex: index < pendingNew.count ? pendingNew[index] : nil
                ))
            }
            pendingOld.removeAll(keepingCapacity: true)
            pendingNew.removeAll(keepingCapacity: true)
        }

        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count,
               newIndex < new.count,
               old[oldIndex] == new[newIndex] {
                flushPending()
                rows.append(DetailedToolDiffRow(
                    oldLineIndex: oldIndex,
                    newLineIndex: newIndex
                ))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < old.count,
                      (newIndex == new.count || lcs[oldIndex + 1][newIndex] >= lcs[oldIndex][newIndex + 1]) {
                pendingOld.append(oldIndex)
                oldIndex += 1
            } else {
                pendingNew.append(newIndex)
                newIndex += 1
            }
        }
        flushPending()
        return rows
    }

    private nonisolated static func detailedToolDiffCell(
        line: String?,
        number: Int?,
        numberWidth: Int,
        width: Int
    ) -> String {
        guard let line, let number else {
            return String(repeating: " ", count: width)
        }
        let prefix = "\(paddedLineNumber(number, width: numberWidth)) │ "
        let terminalSafeLine = terminalSafeSnippetLine(line)
        let availableContentWidth = max(0, width - displayWidth(prefix))
        let fittedLine = displayWidth(terminalSafeLine) > availableContentWidth
            ? TerminalANSIText.truncate(terminalSafeLine, to: availableContentWidth)
            : terminalSafeLine
        return paddedToDisplayWidth("\(prefix)\(fittedLine)", width: width)
    }

    /// Cell for a structurally empty side. The line-number gutter stays blank,
    /// which is what keeps it distinct from a numbered line whose content is
    /// literally the marker text.
    private nonisolated static func detailedToolEmptyPayloadCell(
        isEmpty: Bool,
        numberWidth: Int,
        width: Int
    ) -> String {
        guard isEmpty else {
            return String(repeating: " ", count: width)
        }
        let prefix = "\(String(repeating: " ", count: numberWidth)) │ "
        return paddedToDisplayWidth(
            "\(prefix)\(detailedToolEmptyPayloadMarker)",
            width: width
        )
    }

    /// CRLF is a line ending rather than a source character in this terminal
    /// presentation. Normalize it (and a lone carriage return) before splitting
    /// so no payload can reposition the terminal cursor inside a code cell.
    private nonisolated static func normalizedTerminalLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Emits spaces instead of literal tabs and replaces control characters
    /// with visible, single-column pictures. A literal tab is terminal- and
    /// cursor-position-dependent, so it defeats the width budget used by the
    /// side-by-side layout; an ESC in the payload would additionally inject an
    /// arbitrary escape sequence into the rendered row. Expansion happens only
    /// for presentation; LCS keeps comparing the original source lines,
    /// preserving a tab-vs-space edit.
    private nonisolated static func terminalSafeSnippetLine(_ line: String) -> String {
        let tabWidth = 4
        var rendered = ""
        var currentWidth = 0
        for character in line {
            if character == "\t" {
                let spaces = tabWidth - (currentWidth % tabWidth)
                rendered += String(repeating: " ", count: spaces)
                currentWidth += spaces
                continue
            }
            let safeCharacter = controlPicture(for: character) ?? character
            rendered.append(safeCharacter)
            currentWidth += TerminalANSIText.visibleWidth(of: safeCharacter)
        }
        return rendered
    }

    /// Maps a control character to its single-column Unicode "Control Pictures"
    /// glyph so the payload stays visible and measurable instead of steering
    /// the terminal.
    private nonisolated static func controlPicture(for character: Character) -> Character? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        if scalar.value < 0x20, let picture = Unicode.Scalar(0x2400 + scalar.value) {
            return Character(picture)
        }
        if scalar.value == 0x7F, let picture = Unicode.Scalar(0x2421) {
            return Character(picture)
        }
        return " "
    }

    private nonisolated static func paddedLineNumber(_ number: Int, width: Int) -> String {
        let text = String(number)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private nonisolated static func paddedToDisplayWidth(_ text: String, width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - displayWidth(text)))
    }

    /// Deduces the syntax-highlighting language for the tool's code snippets
    /// from the extension of the file the call targets, so written/edited
    /// code is rendered with proper highlighting in the expanded view.
    nonisolated static func codeLanguageHint(for toolCall: DirectAgentToolCall) -> String? {
        let presentation = ToolCallPresentation.resolved(
            for: toolCall,
            mode: .expanded
        )
        for element in presentation.elements {
            switch element {
            case let .code(_, _, languageHint),
                 let .diff(_, _, _, languageHint):
                if let languageHint = languageHint?.nilIfBlank {
                    return languageHint
                }
            case .parameters, .list, .summary:
                continue
            }
        }
        return nil
    }

    nonisolated static func leadingSpaceCount(_ line: String) -> Int {
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
