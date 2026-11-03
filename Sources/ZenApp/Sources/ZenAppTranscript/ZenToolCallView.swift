//
//  ZenToolCallView.swift
//  ZenApp
//
//  A tool call: the terminal's compact tool line, with the resolved
//  presentation and the bounded output behind a disclosure.
//

import Foundation
import SwiftUI
import ToolCore
import ZenAppTheme
import ZenCODECore

/// A tool call as the terminal's compact line shows it: the status glyph,
/// the tool name in `toolTitle`, its target (the command of `local.exec`) in
/// `toolValue`, and the elapsed time in `toolDuration`. Clicking the line
/// shows the expanded presentation the tool declares (metadata, parameters,
/// code, diff, list, summary) and the bounded output of the result.
public struct ZenToolCallView: View {
    private let call: DirectAgentToolCall
    private let result: DirectAgentToolResult?
    private let duration: Duration?

    @State private var isExpanded = false
    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - call: The tool call.
    ///   - result: Its result, or `nil` while it runs.
    ///   - duration: The elapsed time of the call when the channel measured
    ///     it; the runtime's call and result do not carry one.
    public init(call: DirectAgentToolCall, result: DirectAgentToolResult?, duration: Duration? = nil) {
        self.call = call
        self.result = result
        self.duration = duration
    }

    public var body: some View {
        let status = ZenToolCallStatus(call: call, result: result)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                compactLine(status: status)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the tool details" : "Shows the tool details")

            if isExpanded {
                ZenToolCallDetailsView(call: call, result: result)
                    .padding(.leading, 22)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactLine(status: ZenToolCallStatus) -> some View {
        let line = ZenToolCallFormatting.compactLine(for: call)
        var runs = [
            ZenTextRun(text: ToolCallPresentation.toolIcon(for: call.name) + " ", color: palette.toolTitle),
            ZenTextRun(text: line.title, color: palette.toolTitle, isBold: true)
        ]
        if let target = line.target {
            runs.append(ZenTextRun(text: "  " + target, color: palette.toolValue))
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZenToolStatusGlyph(status: status)
            Text(AttributedString.zen(runs))
                .font(ZenFonts.monoSmall)
                .lineLimit(isExpanded ? 6 : 2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail = ZenToolCallFormatting.completionDetail(for: call, result: result, duration: duration) {
                Text(detail)
                    .font(ZenFonts.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(palette.toolDuration)
                    .fixedSize()
            }
            ZenDisclosureChevron(isExpanded: isExpanded)
        }
        .contentShape(Rectangle())
    }
}

/// The expanded presentation of a tool call: the resolved title and action,
/// metadata, semantic elements, and the bounded result output.
struct ZenToolCallDetailsView: View {
    let call: DirectAgentToolCall
    let result: DirectAgentToolResult?

    @Environment(\.zenPalette) private var palette

    var body: some View {
        let presentation = ToolCallPresentation.resolved(for: call, result: result, mode: .expanded)
        VStack(alignment: .leading, spacing: 8) {
            heading(presentation)
            if !presentation.metadata.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(presentation.metadata.enumerated()), id: \.offset) { _, item in
                        labeledRow(label: item.label, value: item.value, valueColor: palette.toolValue)
                    }
                }
            }
            ForEach(Array(presentation.elements.enumerated()), id: \.offset) { _, element in
                elementView(element)
            }
            if let result {
                outputView(result)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func heading(_ presentation: ResolvedToolPresentation) -> some View {
        let title = ZenTranscriptText.inline(presentation.title)
        let action = presentation.action.flatMap { ZenTranscriptText.inline($0) }
        let parts = [action, title == call.name ? nil : title].compactMap(\.self)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.toolLabel)
        }
    }

    @ViewBuilder
    private func elementView(_ element: ToolPresentationElement) -> some View {
        switch element {
        case let .parameters(label, value):
            VStack(alignment: .leading, spacing: 2) {
                if let label = ZenTranscriptText.nonBlank(label) {
                    ZenDetailLabel(text: label)
                }
                ForEach(Array(ZenToolCallFormatting.parameterRows(for: value, label: label).enumerated()), id: \.offset) { _, row in
                    labeledRow(label: row.key, value: row.value, valueColor: palette.toolParameter)
                }
            }
        case let .code(label, content, _):
            VStack(alignment: .leading, spacing: 4) {
                if let label = ZenTranscriptText.nonBlank(label) {
                    ZenDetailLabel(text: label)
                }
                ZenCodeLinesView(content: content)
            }
        case let .diff(label, old, new, _):
            VStack(alignment: .leading, spacing: 4) {
                if let label = ZenTranscriptText.nonBlank(label) {
                    ZenDetailLabel(text: label)
                }
                ZenDiffRowsView(rows: ZenToolCallFormatting.lineDiff(old: old, new: new))
            }
        case let .list(label, items):
            VStack(alignment: .leading, spacing: 2) {
                if let label = ZenTranscriptText.nonBlank(label) {
                    ZenDetailLabel(text: label)
                }
                ForEach(Array(items.prefix(100).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .foregroundStyle(palette.markdownBullet)
                        Text(ZenToolCallFormatting.displayText(for: item, limit: ZenTranscriptText.inlineLimit))
                            .foregroundStyle(palette.toolParameter)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(ZenFonts.monoSmall)
                }
                if items.count > 100 {
                    Text("… \(items.count - 100) more")
                        .font(.caption)
                        .foregroundStyle(palette.textMuted)
                }
            }
        case let .summary(label, text):
            labeledRow(
                label: ZenTranscriptText.nonBlank(label) ?? "summary",
                value: ZenTranscriptText.bounded(text, limit: 2_000),
                valueColor: palette.toolParameter
            )
        @unknown default:
            // An element newer than the app: the output below still shows.
            EmptyView()
        }
    }

    @ViewBuilder
    private func outputView(_ result: DirectAgentToolResult) -> some View {
        let isFailure = ZenToolCallStatus(call: call, result: result) != .completed
        if ZenTranscriptText.nonBlank(result.output) != nil {
            VStack(alignment: .leading, spacing: 4) {
                ZenDetailLabel(text: result.isPermissionDenied ? "permission denied" : "output")
                ZenToolOutputView(output: result.output, isFailure: isFailure)
            }
        } else if isFailure, let summary = ZenTranscriptText.nonBlank(result.summary) {
            Text(ZenTranscriptText.bounded(summary, limit: 2_000))
                .font(ZenFonts.monoSmall)
                .foregroundStyle(palette.failureMessage)
        }
    }

    private func labeledRow(label: String, value: String, valueColor: Color) -> some View {
        Text(AttributedString.zen([
            ZenTextRun(text: label + ": ", color: palette.toolLabel),
            ZenTextRun(text: value, color: valueColor)
        ]))
        .font(ZenFonts.monoSmall)
        .lineLimit(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Tool calls") {
    let command = DirectAgentToolCall(
        id: "1",
        name: "local.exec",
        argumentsObject: ["command": "swift build --target ZenAppTranscript"],
        argumentsJSON: "",
        descriptorTitle: "Command",
        presentation: ToolPresentationDefinition(
            title: "Command",
            action: "Run",
            kind: .execute,
            target: .argument(["command"])
        )
    )
    let edit = DirectAgentToolCall(
        id: "2",
        name: "custom.edit",
        argumentsObject: ["path": "Sources/App.swift", "old": "let a = 1\nlet b = 2", "new": "let a = 1\nlet b = 3"],
        argumentsJSON: "",
        presentation: ToolPresentationDefinition(
            title: "Edit",
            action: "Edit",
            kind: .edit,
            target: .argument(["path"]),
            sections: [
                .diff(
                    label: "change",
                    old: .argument(["old"]),
                    new: .argument(["new"])
                )
            ]
        )
    )
    let search = DirectAgentToolCall(
        id: "3",
        name: "search.grep",
        argumentsObject: ["pattern": "ZenPalette", "path": "Sources"],
        argumentsJSON: ""
    )
    VStack(alignment: .leading, spacing: 12) {
        ZenToolCallView(call: command, result: nil)
        ZenToolCallView(
            call: command,
            result: DirectAgentToolResult(output: "exit_code: 0\nstdout:\nBuild complete!", summary: "exit_code: 0"),
            duration: .milliseconds(1_420)
        )
        ZenToolCallView(
            call: command,
            result: DirectAgentToolResult(output: "exit_code: 1\nstderr:\nerror: no such target", summary: "exit_code: 1"),
            duration: .milliseconds(380)
        )
        ZenToolCallView(
            call: edit,
            result: DirectAgentToolResult(output: "Edited Sources/App.swift", summary: "edited")
        )
        ZenToolCallView(
            call: search,
            result: DirectAgentToolResult(output: "denied", summary: "denied", status: .permissionDenied)
        )
    }
    .padding()
    .frame(width: 600)
}
