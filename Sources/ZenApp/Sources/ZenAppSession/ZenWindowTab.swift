//
//  ZenWindowTab.swift
//  ZenApp
//
//  The tabs of a window: the conversation, always first, then the transcripts
//  of the sub-agents the operator opened, and which tab a close selects.
//

import Foundation

/// A tab of a window: the conversation of the session (``chat``, always
/// present and never closed) or the transcript of one sub-agent the operator
/// opened (``subAgent(_:)``, by agent id).
public enum ZenWindowTab: Hashable, Sendable {
    /// The conversation, with the composer, the consent card, and the status
    /// bar.
    case chat
    /// The read-only transcript of the sub-agent with this id.
    case subAgent(String)

    /// The sub-agent of the tab; `nil` for ``chat``.
    public var agentID: String? {
        if case let .subAgent(agentID) = self {
            return agentID
        }
        return nil
    }

    /// The tabs of a window whose sub-agent tabs are `agentIDs`, in the order
    /// they were opened: ``chat`` first.
    public static func tabs(subAgentIDs agentIDs: [String]) -> [ZenWindowTab] {
        [.chat] + agentIDs.map(ZenWindowTab.subAgent)
    }

    /// The tab to select after the tab of `closedAgentID` closes, among
    /// `tabs` as they were before the close. A tab other than the closed one
    /// stays selected; the closed tab, when selected, passes the selection to
    /// the tab after it, else to the one before it, which is ``chat`` at
    /// worst.
    public static func selection(
        afterClosing closedAgentID: String,
        in tabs: [ZenWindowTab],
        selected: ZenWindowTab
    ) -> ZenWindowTab {
        let closed = ZenWindowTab.subAgent(closedAgentID)
        guard selected == closed else { return selected }
        guard let index = tabs.firstIndex(of: closed) else { return .chat }
        let remaining = tabs.filter { $0 != closed }
        guard !remaining.isEmpty else { return .chat }
        return remaining[min(index, remaining.count - 1)]
    }
}
