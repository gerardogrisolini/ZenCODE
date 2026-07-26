//
//  TerminalChat+BindingsRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    /// ANSI palette for the `/bindings` card. The orange border matches the
    /// startup box, input panel and status bar identity color, while the inner
    /// colors highlight the values that actually drive agent/model selection:
    /// the profile name, the default binding, the capability score and the
    /// thinking level.
    enum BindingsCardPalette {
        static let reset = "\u{1B}[0m"
        static let border = "\u{1B}[38;5;208m"
        static let title = "\u{1B}[1m\u{1B}[38;5;208m"
        static let agent = "\u{1B}[1m\u{1B}[38;5;231m"
        static let selectedAgent = "\u{1B}[1m\u{1B}[38;5;208m"
        static let activeMarker = "\u{1B}[38;5;208m"
        static let defaultMarker = "\u{1B}[1m\u{1B}[38;5;220m"
        static let marker = "\u{1B}[38;5;240m"
        static let provider = "\u{1B}[38;5;81m"
        static let model = "\u{1B}[38;5;231m"
        static let label = "\u{1B}[38;5;244m"
        static let separator = "\u{1B}[38;5;240m"
        static let thinking = "\u{1B}[38;5;176m"
        static let capabilityHigh = "\u{1B}[38;5;114m"
        static let capabilityMedium = "\u{1B}[38;5;220m"
        static let capabilityLow = "\u{1B}[38;5;244m"
        static let muted = "\u{1B}[38;5;244m"
    }

    /// A single card row kept as a plain/colored pair so the box can measure,
    /// pad and truncate on the plain text while emitting the colored variant.
    struct BindingsCardRow: Sendable {
        let plain: String
        let colored: String

        static let blank = BindingsCardRow(plain: "", colored: "")

        func text(colorsEnabled: Bool) -> String {
            colorsEnabled ? colored : plain
        }
    }

    nonisolated static let bindingsCardTitle = "Agent model bindings"
    nonisolated static let bindingsDefaultMarkerGlyph = "★"
    nonisolated static let bindingsBindingMarkerGlyph = "·"
    nonisolated static let bindingsActiveAgentGlyph = "✱"

    /// Renders the `/bindings` overview as an orange-bordered card that gives
    /// color and emphasis to the active agent, the default binding, the
    /// capability score and the thinking level.
    nonisolated static func renderAgentModelBindingsCard(
        agents: [AgentProfile],
        selectedAgent: AgentProfile?,
        columns: Int = terminalColumnCount(),
        colorsEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        guard !agents.isEmpty else {
            return "No agent model bindings configured.\n"
        }

        let palette = BindingsCardPalette.self
        let border = colorsEnabled ? palette.border : ""
        let reset = colorsEnabled ? palette.reset : ""
        let titleColor = colorsEnabled ? palette.title : ""

        let rows = bindingsCardRows(agents: agents, selectedAgent: selectedAgent)
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let linePrefix = String(repeating: " ", count: horizontalInset)
        // Reserve two border columns plus one padding column on each side.
        let widthBudget = max(24, columns - horizontalInset * 2 - 4)
        let longestRow = rows.map { TerminalANSIText.visibleWidth($0.plain) }.max() ?? 0
        let contentWidth = max(
            min(longestRow, widthBudget),
            min(bindingsCardTitle.count + 2, widthBudget)
        )
        let innerWidth = contentWidth + 2
        // `╭─ title ` already consumes the title text plus three cells.
        let titleFill = max(1, innerWidth - (bindingsCardTitle.count + 3))

        var output = [
            linePrefix
                + border + "╭─ " + reset
                + titleColor + bindingsCardTitle + reset
                + border + " " + String(repeating: "─", count: titleFill) + "╮" + reset
        ]

        for row in rows {
            output.append(
                linePrefix
                    + border + "│" + reset
                    + " "
                    + bindingsCardContent(row, width: contentWidth, colorsEnabled: colorsEnabled)
                    + " "
                    + border + "│" + reset
            )
        }

        output.append(
            linePrefix
                + border
                + "╰" + String(repeating: "─", count: innerWidth) + "╯"
                + reset
        )
        return output.joined(separator: "\n") + "\n"
    }

    /// Truncates on visible width when a row exceeds the card, then pads so the
    /// right border stays aligned regardless of embedded escape sequences.
    private nonisolated static func bindingsCardContent(
        _ row: BindingsCardRow,
        width: Int,
        colorsEnabled: Bool
    ) -> String {
        let text = row.text(colorsEnabled: colorsEnabled)
        let plainWidth = TerminalANSIText.visibleWidth(row.plain)
        guard plainWidth > width else {
            return text + String(repeating: " ", count: width - plainWidth)
        }

        let truncated = TerminalANSIText.truncate(text, to: width)
        let padding = max(0, width - TerminalANSIText.visibleWidth(truncated))
        return truncated
            + (colorsEnabled ? BindingsCardPalette.reset : "")
            + String(repeating: " ", count: padding)
    }

    nonisolated static func bindingsCardRows(
        agents: [AgentProfile],
        selectedAgent: AgentProfile?
    ) -> [BindingsCardRow] {
        let palette = BindingsCardPalette.self
        var rows: [BindingsCardRow] = []
        for (offset, agent) in agents.enumerated() {
            if offset > 0 {
                rows.append(.blank)
            }
            rows.append(bindingsCardAgentRow(agent, isSelected: agent == selectedAgent))
            guard !agent.modelBindings.isEmpty else {
                rows.append(
                    BindingsCardRow(
                        plain: "  (no dedicated model bindings)",
                        colored: "  \(palette.muted)(no dedicated model bindings)\(palette.reset)"
                    )
                )
                continue
            }

            let defaultBindingID = agent.defaultModelBinding?.id
            for binding in agent.modelBindings {
                rows.append(
                    bindingsCardBindingRow(
                        binding,
                        isDefault: binding.id == defaultBindingID
                    )
                )
            }
        }

        guard let legend = bindingsCardLegendRow(
            agents: agents,
            selectedAgent: selectedAgent
        ) else {
            return rows
        }
        rows.append(.blank)
        rows.append(legend)
        return rows
    }

    /// The legend only explains markers that are actually present in the card.
    private nonisolated static func bindingsCardLegendRow(
        agents: [AgentProfile],
        selectedAgent: AgentProfile?
    ) -> BindingsCardRow? {
        let palette = BindingsCardPalette.self
        var plainParts: [String] = []
        var coloredParts: [String] = []

        if agents.contains(where: { $0.defaultModelBinding != nil }) {
            plainParts.append("\(bindingsDefaultMarkerGlyph) default binding")
            coloredParts.append(
                "\(palette.defaultMarker)\(bindingsDefaultMarkerGlyph)\(palette.reset) "
                    + "\(palette.muted)default binding\(palette.reset)"
            )
        }
        if agents.contains(where: { $0 == selectedAgent }) {
            plainParts.append("\(bindingsActiveAgentGlyph) active agent")
            coloredParts.append(
                "\(palette.activeMarker)\(bindingsActiveAgentGlyph)\(palette.reset) "
                    + "\(palette.muted)active agent\(palette.reset)"
            )
        }
        guard !plainParts.isEmpty else {
            return nil
        }
        return BindingsCardRow(
            plain: plainParts.joined(separator: "   "),
            colored: coloredParts.joined(separator: "   ")
        )
    }

    private nonisolated static func bindingsCardAgentRow(
        _ agent: AgentProfile,
        isSelected: Bool
    ) -> BindingsCardRow {
        let palette = BindingsCardPalette.self
        guard isSelected else {
            return BindingsCardRow(
                plain: agent.displayName,
                colored: "\(palette.agent)\(agent.displayName)\(palette.reset)"
            )
        }
        return BindingsCardRow(
            plain: "\(agent.displayName) \(bindingsActiveAgentGlyph)",
            colored: "\(palette.selectedAgent)\(agent.displayName)\(palette.reset)"
                + " \(palette.activeMarker)\(bindingsActiveAgentGlyph)\(palette.reset)"
        )
    }

    private nonisolated static func bindingsCardBindingRow(
        _ binding: AgentModelBinding,
        isDefault: Bool
    ) -> BindingsCardRow {
        let palette = BindingsCardPalette.self
        let markerGlyph = isDefault ? bindingsDefaultMarkerGlyph : bindingsBindingMarkerGlyph
        var plain = "  \(markerGlyph) "
        var colored = "  "
            + (isDefault
                ? "\(palette.defaultMarker)\(markerGlyph)\(palette.reset)"
                : "\(palette.marker)\(markerGlyph)\(palette.reset)")
            + " "

        if let provider = binding.modelProvider {
            plain += "\(provider) / "
            colored += "\(palette.provider)\(provider)\(palette.reset)"
                + "\(palette.separator) / \(palette.reset)"
        }
        let modelName = Self.strippedModelNameForBinding(
            binding.modelID,
            modelProvider: binding.modelProvider
        )
        plain += modelName
        colored += "\(palette.model)\(modelName)\(palette.reset)"

        if let capability = binding.capability {
            plain += " · capability: \(capability)/10"
            colored += "\(palette.separator) · \(palette.reset)"
                + "\(palette.label)capability: \(palette.reset)"
                + "\(bindingsCapabilityColor(capability))\(capability)/10\(palette.reset)"
        }
        if let thinkingSelection = binding.thinkingSelection {
            plain += " · thinking: \(thinkingSelection.displayTitle)"
            colored += "\(palette.separator) · \(palette.reset)"
                + "\(palette.label)thinking: \(palette.reset)"
                + "\(palette.thinking)\(thinkingSelection.displayTitle)\(palette.reset)"
        }
        return BindingsCardRow(plain: plain, colored: colored)
    }

    /// Capability is the primary model-selection signal, so it is graded by
    /// value: green for powerful models, amber for balanced ones, gray for
    /// lightweight ones.
    nonisolated static func bindingsCapabilityColor(_ capability: Int) -> String {
        switch capability {
        case 7...:
            return BindingsCardPalette.capabilityHigh
        case 4...6:
            return BindingsCardPalette.capabilityMedium
        default:
            return BindingsCardPalette.capabilityLow
        }
    }
}
