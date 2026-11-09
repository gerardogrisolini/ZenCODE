//
//  TerminalChat+SubAgents+Presentation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// Stable affordance shown while an agent is reasoning but has no
    /// renderable paragraph yet. Presentation owns this string: the runtime
    /// reports the thinking phase through `currentActivityKind`.
    nonisolated static let thinkingPlaceholder = "🤔 thinking…"

    /// Formats the replaceable reasoning value with the coordinator's Markdown
    /// and muted thinking styles, bounded by the existing overview width.
    nonisolated static func renderSubAgentThinkingMarkdown(
        _ source: String,
        standardErrorIsTerminal: Bool = AgentOutput.standardErrorIsTerminal,
        renderWidth: Int? = nil
    ) -> String? {
        let sanitized = sanitizedSubAgentThinkingText(source, preservingTabs: true)
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var boldBreakState = TerminalChatBoldBreakState()
        var normalized = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            sanitized,
            state: &boldBreakState
        )
        normalized += TerminalChatTextFormatting.flushBoldSectionBreak(state: &boldBreakState)
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: standardErrorIsTerminal,
            renderWidth: renderWidth ?? TerminalSubAgentOverviewLayout.overviewWrapWidth(indentation: 3),
            // Only renderer-owned SGR may reach the in-place slot, never OSC.
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )
        let rendered = formatter.consume(normalized) + formatter.finish()
        // Markdown entities can decode to controls too. Reapply the safety
        // boundary after parsing, allowing only SGR for the thinking style pass.
        return TerminalChatTextFormatting.renderThoughtMarkdown(
            sanitizedSubAgentThinkingText(rendered, preservingSGR: true),
            standardErrorIsTerminal: standardErrorIsTerminal
        )
    }

    private nonisolated static func sanitizedSubAgentThinkingText(
        _ source: String,
        preservingTabs: Bool = false,
        preservingSGR: Bool = false
    ) -> String {
        // Preserve structural LF, and TAB only before Markdown so the shared
        // parser and code renderer own indentation and tab-stop expansion.
        // The post-parse safety pass still neutralizes any remaining TAB.
        let source = source.replacingOccurrences(of: "\r\n", with: "\n")
        var sanitized = ""
        sanitized.reserveCapacity(source.count)
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if preservingSGR, source[cursor...].hasPrefix("\u{1B}[") {
                var end = source.index(cursor, offsetBy: 2)
                while end < source.endIndex, "0123456789;".contains(source[end]) {
                    end = source.index(after: end)
                }
                if end < source.endIndex, source[end] == "m" {
                    sanitized += source[cursor...end]
                    cursor = source.index(after: end)
                    continue
                }
            }
            let character = source[cursor]
            let isStructuralWhitespace = character == "\n" || (preservingTabs && character == "\t")
            let isControl = !isStructuralWhitespace && character.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar.properties.isBidiControl
                    || scalar.properties.isJoinControl
            }
            sanitized.append(isControl ? " " : character)
            cursor = source.index(after: cursor)
        }
        return sanitized
    }
}
