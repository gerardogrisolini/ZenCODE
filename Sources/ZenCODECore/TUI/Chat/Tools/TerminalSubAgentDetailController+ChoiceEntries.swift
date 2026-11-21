//
//  TerminalSubAgentDetailController+ChoiceEntries.swift
//  ZenCODE
//
//  The entries of the agent list of the sub-agent detail panel: one title and
//  a block of aligned, muted detail fields per snapshot.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalSubAgentDetailController {
    /// One entry per snapshot, made only of what does not go stale while the
    /// list is open (no status, no activity, no counters, no error):
    ///
    /// - the title is the agent's name alone (its id when the name is blank);
    /// - the detail rows are a block of one field per line, in the order of the
    ///   detail header and with its muted labels
    ///   (``choiceDetails(_:showsID:modelTitleResolver:)``): `id:` (only for an agent
    ///   whose name another entry shares), `agent:`, `task:` with its
    ///   `attempt:`, and `model:`. A missing field is left out, and so are the
    ///   rows of an agent without fields.
    static func choiceEntries(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String
    ) -> [TerminalSubAgentDetailPanel.ChoiceEntry] {
        let names = snapshots.map { $0.name.nilIfBlank ?? $0.id }
        let counts = names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return zip(snapshots, names).map { snapshot, name in
            let isShared = counts[name, default: 0] > 1 && name != snapshot.id
            return TerminalSubAgentDetailPanel.ChoiceEntry(
                id: snapshot.id,
                title: name,
                details: choiceDetails(
                    snapshot,
                    showsID: isShared,
                    modelTitleResolver: modelTitleResolver
                )
            )
        }
    }

    /// The labels of the detail rows of ``choiceEntries(_:modelTitleResolver:)``.
    private nonisolated static let choiceLabels = (id: "id:", agent: "agent:", task: "task:", model: "model:")

    /// The width every label of the list is completed to, so the values start
    /// at the same column: the longest of the four labels.
    private nonisolated static let choiceLabelWidth = [
        choiceLabels.id, choiceLabels.agent, choiceLabels.task, choiceLabels.model
    ].map(\.count).max() ?? 0

    /// The detail rows of ``choiceEntries(_:modelTitleResolver:)``, one field
    /// per row, in the order of the detail header:
    ///
    /// - `id:`, the agent's id, when `showsID` (another entry shares the
    ///   agent's name);
    /// - `agent:`, the profile name;
    /// - `task:`, the task id, followed by ` · attempt: N` when the attempt is
    ///   known;
    /// - `model:`, the title of the configured model (the one the backend
    ///   reported when none is configured), without the token counters
    ///   (``TerminalSubAgentOverviewLayout/modelTitle(_:modelTitleResolver:)``).
    ///
    /// Each label is muted and completed with spaces to the width of the
    /// longest one (the padding stays inside the muted span), so the values
    /// start at the same column. A blank field is left out.
    private static func choiceDetails(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        showsID: Bool,
        modelTitleResolver: (String) -> String
    ) -> [String] {
        typealias Layout = TerminalSubAgentOverviewLayout
        func field(_ label: String, _ value: String) -> String {
            let padding = String(repeating: " ", count: max(0, choiceLabelWidth - label.count))
            return Layout.metadataText(label: label + padding, value: value)
        }
        var rows: [String] = []
        if showsID {
            rows.append(field(choiceLabels.id, snapshot.id))
        }
        let profile = InlineTextTruncation.inlineText(snapshot.profileName ?? "")
        if !profile.isEmpty {
            rows.append(field(choiceLabels.agent, profile))
        }
        let taskID = InlineTextTruncation.inlineText(snapshot.taskID ?? "")
        if !taskID.isEmpty {
            var task = field(choiceLabels.task, taskID)
            if let attempt = snapshot.taskAttemptOrdinal {
                task += " \(Layout.dimText("·")) " + Layout.metadataText(label: "attempt:", value: String(attempt))
            }
            rows.append(task)
        }
        if let model = Layout.modelTitle(snapshot, modelTitleResolver: modelTitleResolver) {
            rows.append(field(choiceLabels.model, model))
        }
        return rows
    }
}
