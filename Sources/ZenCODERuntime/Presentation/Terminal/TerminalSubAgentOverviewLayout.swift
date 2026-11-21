//
//  TerminalSubAgentOverviewLayout.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// Lays out the sub-agent overview: the section of rows that lists every
/// delegated agent, its status, metadata and current activity. It is made of
/// pure functions of the agent snapshots and the available width; the
/// publication, refresh and in-place rewrite of the section stay with
/// `TerminalChat` and the render coordinator.
///
/// The rows may carry the terminal's styling (when the standard error is a
/// terminal). Telegram reuses ``statusRows(_:)``, ``partialResponses(_:)`` and
/// ``markdownResponses(_:)`` and strips that styling itself.
///
/// The layout is shared: this module holds the inline rows and the responses
/// Telegram reuses, while the terminal UI in `ZenCODECore` extends it with the
/// section's density variants, tool rows and rendered thinking.
package enum TerminalSubAgentOverviewLayout {
    package struct Line {
        package let text: String
        package let indentation: Int
        package let maxWrappedLines: Int
        package let dimPrefix: Bool
        package let clipsOverflowWithoutEllipsis: Bool

        package static func summary(_ text: String) -> Line {
            Line(
                text: text,
                indentation: 3,
                maxWrappedLines: 3,
                dimPrefix: true,
                clipsOverflowWithoutEllipsis: false
            )
        }

        package static func regular(
            _ text: String,
            maxWrappedLines: Int = 3,
            clipsOverflowWithoutEllipsis: Bool = false
        ) -> Line {
            Line(
                text: text,
                indentation: 3,
                maxWrappedLines: maxWrappedLines,
                dimPrefix: false,
                clipsOverflowWithoutEllipsis: clipsOverflowWithoutEllipsis
            )
        }

        /// Complete model messages are emitted only after their delta stream has
        /// reached a semantic boundary. Do not tail-truncate them: the update is
        /// published once, with the whole message kept together.
        package static func complete(
            _ text: String,
            indentation: Int = 3
        ) -> Line {
            Line(
                text: text,
                indentation: indentation,
                maxWrappedLines: .max,
                dimPrefix: false,
                clipsOverflowWithoutEllipsis: false
            )
        }
    }

    /// The overview as compact rows for a remote chat, without the section's
    /// geometry: the summary row, then one row per agent at the inline
    /// density (status marker, name, status badge, and the current activity:
    /// the latest error, the reasoning placeholder, the latest assistant
    /// block, or the tool it runs). Rows may still carry the terminal's
    /// styling; the caller strips it. No row for an empty overview.
    static func statusRows(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [String] {
        guard !snapshots.isEmpty else { return [] }
        return [summaryText(snapshots)] + snapshots.map(inlineEntry)
    }

    /// Presentation density of the sub-agent section. The live section is replaced
    /// in place only while it fits the scrolling region; denser variants keep that
    /// rewrite slot when many agents run, instead of appending a copy per refresh.
    package enum Density: CaseIterable {
        /// Every metadata line, with multi-row activity and detail text.
        case full
        /// Status header, agent/model identity, and capped activity lines,
        /// with a blank separator row before each agent.
        case compact
        /// Status header plus a single activity line, with a blank separator
        /// row before each agent.
        case dense
        /// One row per agent: status header with an inline activity fragment.
        case inline

        /// Whether a blank row precedes each agent. Every multi-row
        /// presentation keeps it, so consecutive agents never run together.
        package var includesSeparators: Bool {
            self != .inline
        }

        package var includesMetadata: Bool {
            self == .full
        }

        /// Whether the entry keeps the single `agent:` / `model:` identity row
        /// in place of the full metadata lines.
        package var includesAgentAndModel: Bool {
            self == .compact
        }

        /// Whether the running tool is laid out with the canonical tool rows
        /// instead of the one-row fallback.
        package var usesCanonicalToolRows: Bool {
            switch self {
            case .full, .compact: true
            case .dense, .inline: false
            }
        }

        /// Rows a single activity or detail entry may occupy.
        package var maximumEntryRows: Int {
            self == .full ? .max : 1
        }

        /// Activity lines kept per agent, or `nil` when all are kept.
        package var activityLineLimit: Int? {
            switch self {
            case .full: nil
            case .compact: 2
            case .dense, .inline: 1
            }
        }
    }

    /// Folds one agent into a single row: status header plus the most
    /// significant progress fragment.
    package static func inlineEntry(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let header = headerText(snapshot)
        return inlineFragment(snapshot).map { "\(header)  \(dimText("·")) \($0)" } ?? header
    }

    private static func inlineFragment(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            return "❌ \(InlineTextTruncation.inlineText(latestError))"
        }
        return inlineActivityLines(snapshot).first?.text
    }

    /// The activity lines of the inline density, the only one a remote chat
    /// shows: the terminal's `activityLines(_:toolPresentation:density:)`
    /// without a tool presentation. The inline row keeps only the first
    /// thinking line, the stable title, so the model-authored paragraph the
    /// terminal renders below it is never part of this density.
    private static func inlineActivityLines(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> [Line] {
        let density = Density.inline
        let currentToolName = snapshot.currentToolName?.nilIfBlank
        let currentActivity = snapshot.currentActivity?.nilIfBlank
        var lines: [Line] = []

        switch snapshot.currentActivityKind {
        case .thinking:
            lines.append(thinkingPlaceholderLine)
        case .content, nil:
            if let currentActivity {
                lines.append(
                    entryLine(
                        "💬 \(InlineTextTruncation.inlineText(currentActivity))",
                        density: density
                    )
                )
            }
        }

        if let currentToolName,
           !ToolRenderingPolicy.shouldSuppressToolRendering(for: currentToolName) {
            lines.append(
                toolFallbackLine(
                    name: currentToolName,
                    target: snapshot.currentToolTarget?.nilIfBlank,
                    density: density
                )
            )
        }

        if lines.isEmpty, snapshot.pending {
            lines.append(thinkingPlaceholderLine)
        }

        if let limit = density.activityLineLimit, lines.count > limit {
            lines = snapshot.currentActivityKind == .thinking
                ? Array(lines.prefix(limit))
                : Array(lines.suffix(limit))
        }

        return lines
    }

    package static func summaryText(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        let completedCount = snapshots.filter { snapshot in
            snapshot.status == .idle && snapshot.latestOutput?.nilIfBlank != nil
        }.count
        func count(_ status: DirectSubAgentRuntime.Status) -> Int {
            snapshots.filter { $0.status == status }.count
        }
        let counted: [(Int, String, String?)] = [
            (snapshots.filter(\.pending).count, "▸ %d active", TerminalStyle.Status.active),
            (completedCount, "✓ %d completed", TerminalStyle.Status.success),
            (count(.standby), "◇ %d standby", TerminalStyle.Status.inactive),
            (count(.failed), "✗ %d failed", TerminalStyle.Status.failure),
            (count(.closed), "· %d closed", nil)
        ]
        let segments = counted.filter { $0.0 > 0 }.map { number, format, code in
            let text = format.replacingOccurrences(of: "%d", with: String(number))
            return code.map { colorText(text, code: $0) } ?? dimText(text)
        }
        return (["\(snapshots.count) total"] + segments).joined(separator: " ")
    }

    package static func headerText(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let name = snapshot.name.nilIfBlank ?? snapshot.id
        let marker = coloredStatusMarker(for: snapshot)
        let badge = statusBadge(for: snapshot)
        return "\(marker) \(boldText(name))  \(badge)"
    }

    // MARK: - Activity

    /// Stable affordance shown while an agent is reasoning but has no
    /// renderable paragraph yet. Presentation owns this string: the runtime
    /// reports the thinking phase through `currentActivityKind`.
    package static let thinkingPlaceholder = "🤔 thinking…"

    package static var thinkingPlaceholderLine: Line {
        .regular(colorText(thinkingPlaceholder, code: TerminalStyle.Thinking.title), maxWrappedLines: 1)
    }

    /// Compatibility projection used before a lossless lifecycle event arrives
    /// (and by non-terminal/static snapshot consumers).
    package static func toolFallbackLine(
        name: String,
        target: String?,
        density: Density
    ) -> Line {
        let tool = colorText(InlineTextTruncation.inlineText(name), code: TerminalStyle.Tool.title)
        let parameter = (target?.nilIfBlank).map {
            colorText(" \(InlineTextTruncation.inlineText($0))", code: TerminalStyle.Tool.value)
        } ?? ""
        let text = "🛠️  \(tool)\(parameter)"
        return density == .full
            ? entryLine(text, density: density)
            : .regular(
                text,
                maxWrappedLines: 1,
                clipsOverflowWithoutEllipsis: true
            )
    }

    /// Builds one activity or detail line at the requested density: unbounded
    /// for the full presentation, single-row for the denser variants.
    package static func entryLine(
        _ text: String,
        density: Density
    ) -> Line {
        density.maximumEntryRows == .max
            ? .complete(text)
            : .regular(text, maxWrappedLines: density.maximumEntryRows)
    }

    // MARK: - Responses

    /// Extracts completed model responses from the snapshot presentation. The
    /// surrounding overview remains pre-rendered terminal text, while each
    /// response stays as source Markdown so the coordinator can format it with
    /// the same renderer used for normal assistant messages.
    package static func markdownResponses(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [TerminalSubAgentMarkdownResponse] {
        snapshots.compactMap { snapshot in
            guard !snapshot.pending,
                  snapshot.latestError?.nilIfBlank == nil,
                  let output = snapshot.latestContentPreview?.nilIfBlank
                    ?? snapshot.latestOutput?.nilIfBlank else {
                return nil
            }
            let name = snapshot.name.nilIfBlank ?? snapshot.id
            return TerminalSubAgentMarkdownResponse(
                token: responseToken(snapshot: snapshot, output: output),
                heading: "   ✅ Response from \(InlineTextTruncation.inlineText(name)):\n",
                markdown: output
            )
        }
    }

    /// Extracts the same completed assistant blocks shown as 💬 activity rows.
    /// Content appears here only after the runtime reaches a tool boundary, so
    /// Telegram receives semantic partial responses rather than token deltas.
    package static func partialResponses(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [TerminalSubAgentPartialResponse] {
        snapshots.compactMap { snapshot in
            guard snapshot.currentActivityKind == .content,
                  let content = snapshot.currentActivity?.nilIfBlank else {
                return nil
            }
            let name = snapshot.name.nilIfBlank ?? snapshot.id
            return TerminalSubAgentPartialResponse(
                token: [
                    snapshot.id,
                    "partial",
                    String(snapshot.currentActivityRevision)
                ].joined(separator: "\u{1F}"),
                heading: "💬 \(InlineTextTruncation.inlineText(name)):",
                markdown: content
            )
        }
    }

    /// Produces a compact deterministic identity for one completion. Runtime
    /// snapshots carry a monotonic completion revision, so metadata-only changes
    /// (for example closing an agent) cannot make an old response appear new.
    /// The digest is a fallback for manually constructed legacy snapshots.
    private static func responseToken(
        snapshot: DirectSubAgentRuntime.AgentSnapshot,
        output: String
    ) -> String {
        if snapshot.latestOutputRevision > 0 {
            return [snapshot.id, String(snapshot.latestOutputRevision)].joined(separator: "\u{1F}")
        }

        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in output.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return [snapshot.id, String(digest, radix: 16)].joined(separator: "\u{1F}")
    }

    // MARK: - Styling

    private static func statusBadge(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        colorText("[\(displayStatus(for: snapshot).uppercased())]", code: statusColorCode(for: snapshot))
    }

    private static func boldText(_ text: String) -> String {
        colorText(text, code: TerminalStyle.Attribute.bold)
    }

    package static func dimText(_ text: String) -> String {
        colorText(text, code: TerminalStyle.Text.muted)
    }

    package static func colorText(_ text: String, code: String) -> String {
        AgentOutput.standardErrorIsTerminal ? "\(code)\(text)\(TerminalStyle.reset)" : text
    }

    private static func displayStatus(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        if snapshot.status == .idle,
           snapshot.latestOutput?.nilIfBlank != nil {
            return "completed"
        }
        return snapshot.status.rawValue
    }

    private static func statusColorCode(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        switch snapshot.status {
        case .queued: TerminalStyle.Status.queued
        case .running: TerminalStyle.Status.active
        case .idle:
            snapshot.latestOutput?.nilIfBlank == nil
                ? TerminalStyle.Status.inactive
                : TerminalStyle.Status.success
        case .standby, .closed: TerminalStyle.Status.inactive
        case .failed: TerminalStyle.Status.failure
        }
    }

    private static func coloredStatusMarker(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        colorText("●", code: statusColorCode(for: snapshot))
    }
}

/// One completed sub-agent response waiting to be presented. `token` is a
/// stable identity for that completion, allowing the overview metadata to
/// be refreshed without printing the same model-authored response again.
package struct TerminalSubAgentMarkdownResponse: Sendable, Equatable {
    package let token: String
    package let heading: String
    package let markdown: String
}

/// One assistant block that a sub-agent completed before starting a tool.
/// The same block is shown as a 💬 row in the live overview, consumed once
/// even when later refreshes redraw that row.
package struct TerminalSubAgentPartialResponse: Sendable, Equatable {
    package let token: String
    package let heading: String
    package let markdown: String
}
