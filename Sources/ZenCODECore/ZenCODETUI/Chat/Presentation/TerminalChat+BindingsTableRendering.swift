//
//  TerminalChat+BindingsTableRendering.swift
//  ZenCODE
//

import Foundation
import Markdown

extension TerminalChat {
    /// Glyphs shared with the plain setup summary where applicable.
    nonisolated static let bindingsDefaultMarkerGlyph = "★"
    nonisolated static let bindingsBindingMarkerGlyph = "·"
    nonisolated static let bindingsActiveAgentGlyph = "✱"

    /// Renders the `/bindings` overview as a GFM table routed through the
    /// shared markdown renderer (`TerminalSwiftMarkdownRenderer`), reusing its
    /// box-drawing table layout and column fitting instead of a bespoke card.
    ///
    /// The table is flat (one row per binding), so the profile name is shown
    /// only on the first row of each agent group. Provider and Model are shown
    /// in separate columns, and a horizontal separator (rendered as a middle
    /// border by the shared renderer) is inserted between agent groups.
    nonisolated static func renderAgentModelBindingsTable(
        agents: [AgentProfile],
        selectedAgent: AgentProfile?,
        columns: Int = terminalColumnCount(),
        colorsEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        guard !agents.isEmpty else {
            return "No agent model bindings configured.\n"
        }

        let separatorRow = TerminalSwiftMarkdownRenderer.tableSeparatorRow(columnCount: 6)

        var lines: [String] = [
            "| Profile | Default | Provider | Model | Capability | Thinking |",
            "|---|:---:|---|---|:---:|:---:|"
        ]

        for (agentIndex, agent) in agents.enumerated() {
            let activeSuffix = agent == selectedAgent ? " \(bindingsActiveAgentGlyph)" : ""
            let profileCell = "**\(agent.displayName)\(activeSuffix)**"

            if agent.modelBindings.isEmpty {
                lines.append("| \(profileCell) |  |  | _no dedicated model bindings_ |  |  |")
            } else {
                let defaultBindingID = agent.defaultModelBinding?.id
                for (index, binding) in agent.modelBindings.enumerated() {
                    let profile = index == 0 ? profileCell : ""
                    let defaultGlyph = binding.id == defaultBindingID
                        ? bindingsDefaultMarkerGlyph
                        : bindingsBindingMarkerGlyph
                    let modelName = Self.strippedModelNameForBinding(
                        binding.modelID,
                        modelProvider: binding.modelProvider
                    )
                    let provider = binding.modelProvider ?? "—"
                    let capability = binding.capability.map { "\($0)/10" } ?? "—"
                    let thinking = binding.thinkingSelection?.displayTitle ?? "—"
                    lines.append("| \(profile) | \(defaultGlyph) | \(provider) | \(modelName) | \(capability) | \(thinking) |")
                }
            }

            // Insert a separator between agents (not after the last one).
            if agentIndex < agents.count - 1 {
                lines.append(separatorRow)
            }
        }

        let markdown = lines.joined(separator: "\n") + "\n"
        var renderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false,
            renderWidth: columns > 0 ? max(1, columns - 1) : 0
        )
        let document = Document(parsing: markdown)
        let rendered = renderer.visit(document)
        return colorsEnabled ? rendered : TerminalANSIText.stripANSI(rendered)
    }
}
