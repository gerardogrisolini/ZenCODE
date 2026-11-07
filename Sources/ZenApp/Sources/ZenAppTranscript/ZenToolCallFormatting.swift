//
//  ZenToolCallFormatting.swift
//  ZenApp
//
//  Pure helpers of the tool-call views: lifecycle status, compact title and
//  target, completion detail, line diff, and parameter rows. They mirror the
//  terminal UI's compact tool line (`TerminalChat+ToolRendering`).
//

import Foundation
import ToolCore
import ZenCODECore

/// The lifecycle state of a tool call, as its compact line shows it.
public enum ZenToolCallStatus: Sendable, Equatable, CaseIterable {
    /// No result yet.
    case running
    case completed
    /// The result failed, or `local.exec` exited with a non-zero code.
    case failed
    /// The operator or the policy refused the call.
    case permissionDenied

    /// The status of `call` given its `result` (`nil` while it runs).
    public init(call: DirectAgentToolCall, result: DirectAgentToolResult?) {
        guard let result else {
            self = .running
            return
        }
        if result.isPermissionDenied {
            self = .permissionDenied
        } else if result.isFailure
            || (ZenToolCallFormatting.localExecExitCode(for: call, result: result).map { $0 != 0 } ?? false) {
            self = .failed
        } else {
            self = .completed
        }
    }

    /// The glyph of the status: `●` running, `✓` completed, `✗` failed,
    /// `⊘` permission denied.
    public var glyph: String {
        switch self {
        case .running: "●"
        case .completed: "✓"
        case .failed: "✗"
        case .permissionDenied: "⊘"
        }
    }

    /// The color role of the status.
    public var role: ZenStatusRole {
        switch self {
        case .running: .active
        case .completed: .success
        case .failed, .permissionDenied: .failure
        }
    }
}

/// The compact line of a tool call: the exact tool name and its display target.
public struct ZenToolCompactLine: Sendable, Equatable {
    /// The tool name, the title of the terminal's compact block.
    public let title: String
    /// The target of the call on one line (the command of `local.exec`, a
    /// path, a query), or `nil` when the call has none.
    public let target: String?

    public init(title: String, target: String?) {
        self.title = title
        self.target = target
    }
}

/// One row of a line diff.
public struct ZenTranscriptDiffRow: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case context
        case addition
        case deletion
    }

    public let kind: Kind
    /// The 1-based line in the old text, `nil` for an addition.
    public let oldLineNumber: Int?
    /// The 1-based line in the new text, `nil` for a deletion.
    public let newLineNumber: Int?
    /// The line without its terminator.
    public let text: String

    public init(kind: Kind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

/// One key/value row of a `.parameters` element.
public struct ZenToolParameterRow: Sendable, Equatable {
    public let key: String
    /// The value as display text, bounded.
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Pure presentation helpers of tool calls.
public enum ZenToolCallFormatting {
    /// Output lines a completed call shows before "Show more".
    public static let outputPreviewLineLimit = 40
    /// Output lines a call shows after "Show more".
    public static let outputExpandedLineLimit = 2_000
    /// Lines a code or diff element shows before "Show more".
    public static let codePreviewLineLimit = 200
    /// Lines compared by a line diff; longer inputs are cut first.
    public static let diffLineLimit = 4_000

    /// Whether the transcript hides a tool call, as the terminal does
    /// (`agent.message` is delivered through the shared chat instead).
    public static func isHidden(toolName: String) -> Bool {
        toolName == "agent.message"
    }

    /// The compact line of `call`: the tool name and the target the tool's
    /// presentation declares (for `local.exec` the command, collapsed to one
    /// line), or the safe argument the shared presentation falls back to for a
    /// call without a presentation.
    public static func compactLine(for call: DirectAgentToolCall) -> ZenToolCompactLine {
        let title = ZenTranscriptText.inline(call.name) ?? "tool"
        let rawTarget: String?
        if call.presentation != nil {
            rawTarget = ToolCallPresentation.displayToolTarget(for: call)
        } else {
            // `toolTitle(for:)` is the exact name followed by the fallback
            // argument target, when there is one.
            let toolTitle = ToolCallPresentation.toolTitle(for: call)
            let prefix = call.name + " "
            rawTarget = toolTitle.hasPrefix(prefix) ? String(toolTitle.dropFirst(prefix.count)) : nil
        }
        return ZenToolCompactLine(
            title: title,
            target: rawTarget.flatMap { ZenTranscriptText.inline($0) }
        )
    }

    /// The completion detail of the compact line: the elapsed time when it is
    /// known, and `exit N` for a `local.exec` that exited with a non-zero code.
    public static func completionDetail(
        for call: DirectAgentToolCall,
        result: DirectAgentToolResult?,
        duration: Duration?
    ) -> String? {
        var components: [String] = []
        if let duration {
            components.append(elapsedText(duration))
        }
        if let result,
           let exitCode = localExecExitCode(for: call, result: result),
           exitCode != 0 {
            components.append("exit \(exitCode)")
        }
        return components.isEmpty ? nil : components.joined(separator: " ")
    }

    /// The exit code of a `local.exec` result, read only from the canonical
    /// leading `exit_code: N` line of its summary or output.
    public static func localExecExitCode(
        for call: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> Int? {
        guard call.name == "local.exec" else { return nil }
        for payload in [result.summary, result.output] {
            guard let line = payload.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first else {
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "exit_code: "
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count)
            let digits = value.first == "-" ? value.dropFirst() : value[...]
            if !digits.isEmpty, digits.allSatisfy(\.isWholeNumber), let code = Int(value) {
                return code
            }
        }
        return nil
    }

    /// An elapsed tool time as the terminal writes it: `1.25s`, `420ms`,
    /// `8.40ms`, `<0.01ms`. Delegates to ``ToolCallPresentation/elapsedTimeText(_:)``.
    public static func elapsedText(_ duration: Duration) -> String {
        ToolCallPresentation.elapsedTimeText(duration)
    }

    // MARK: - Line diff

    /// The lines of `text` without their terminators. CRLF and CR are line
    /// breaks; a final line break does not add an empty last line.
    public static func lines(of text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [] }
        var parts = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") {
            parts.removeLast()
        }
        return parts
    }

    /// The line diff that turns `old` into `new`, computed with
    /// `CollectionDifference` over the lines: unchanged lines as context,
    /// removed lines before the inserted lines that replace them.
    public static func lineDiff(old: String, new: String) -> [ZenTranscriptDiffRow] {
        let oldLines = Array(lines(of: old).prefix(diffLineLimit))
        let newLines = Array(lines(of: new).prefix(diffLineLimit))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [ZenTranscriptDiffRow] = []
        rows.reserveCapacity(max(oldLines.count, newLines.count))
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                rows.append(ZenTranscriptDiffRow(
                    kind: .deletion, oldLineNumber: oldIndex + 1, newLineNumber: nil, text: oldLines[oldIndex]
                ))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                rows.append(ZenTranscriptDiffRow(
                    kind: .addition, oldLineNumber: nil, newLineNumber: newIndex + 1, text: newLines[newIndex]
                ))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                rows.append(ZenTranscriptDiffRow(
                    kind: .context, oldLineNumber: oldIndex + 1, newLineNumber: newIndex + 1, text: oldLines[oldIndex]
                ))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return rows
    }

    /// The hunks of a diff: the changed rows with up to `context` unchanged
    /// rows around them, overlapping ranges merged. An unchanged diff has none.
    public static func contextHunks(
        _ rows: [ZenTranscriptDiffRow],
        context: Int = 3
    ) -> [[ZenTranscriptDiffRow]] {
        let context = max(0, context)
        var ranges: [Range<Int>] = []
        for index in rows.indices where rows[index].kind != .context {
            let range = max(0, index - context)..<min(rows.count, index + context + 1)
            if let last = ranges.last, last.upperBound >= range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { Array(rows[$0]) }
    }

    // MARK: - Parameters and lists

    /// The rows of a `.parameters` value: one row per key of an object, in
    /// key order, or a single `label` row for any other value.
    public static func parameterRows(for value: JSONValue, label: String? = nil) -> [ZenToolParameterRow] {
        if case let .object(object) = value {
            return object.keys.sorted().map { key in
                ZenToolParameterRow(key: key, value: displayText(for: object[key] ?? .null))
            }
        }
        return [ZenToolParameterRow(key: ZenTranscriptText.nonBlank(label) ?? "value", value: displayText(for: value))]
    }

    /// A JSON value as bounded display text: strings as they are, scalars in
    /// their plain form, objects and arrays as compact JSON.
    public static func displayText(for value: JSONValue, limit: Int = 2_000) -> String {
        let text: String
        switch value {
        case let .string(string):
            text = string
        case .number, .bool:
            text = value.flexibleStringValue ?? value.compactString(sortedKeys: true)
        case .null:
            text = "null"
        case .object, .array:
            text = value.compactString(sortedKeys: true)
        @unknown default:
            text = value.compactString(sortedKeys: true)
        }
        return ZenTranscriptText.bounded(text, limit: limit)
    }
}
