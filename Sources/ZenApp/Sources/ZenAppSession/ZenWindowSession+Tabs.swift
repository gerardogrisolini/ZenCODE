//
//  ZenWindowSession+Tabs.swift
//  ZenApp
//
//  The tabs of a window: the conversation and the transcript of each
//  sub-agent the operator opened.
//

import Foundation
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Tabs

    /// The model of the open tab of the sub-agent `agentID`; `nil` when no
    /// such tab is open.
    public func subAgentTab(_ agentID: String) -> ZenSubAgentTranscriptModel? {
        subAgentTabs.first { $0.agentID == agentID }
    }

    /// Opens the tab of the sub-agent `agentID` of the current session, after
    /// the open ones, unless it is open already, and selects it. The tab
    /// starts with the agent's snapshot from the latest overview and follows
    /// the agent from then on, selected before it starts.
    public func openSubAgentTab(_ agentID: String) {
        guard !isClosed else { return }
        guard subAgentTab(agentID) == nil else {
            selectTab(.subAgent(agentID))
            return
        }
        let model = ZenSubAgentTranscriptModel(
            agentID: agentID,
            snapshot: subAgents.snapshots.first { $0.id == agentID },
            source: .incarnation(epoch: current.epoch, agentID: agentID, in: sessionHost, slotID: slotID)
        )
        subAgentTabs.append(model)
        selectTab(.subAgent(agentID))
        model.start()
    }

    /// Closes the tab of the sub-agent `agentID` and stops its model. When it
    /// was selected, the tab after it is selected, else the one before it
    /// (``ZenWindowTab/selection(afterClosing:in:selected:)``).
    public func closeSubAgentTab(_ agentID: String) {
        guard let index = subAgentTabs.firstIndex(where: { $0.agentID == agentID }) else { return }
        let selection = ZenWindowTab.selection(afterClosing: agentID, in: tabs, selected: selectedTab)
        subAgentTabs[index].stop()
        subAgentTabs.remove(at: index)
        setSelectedTab(selection)
    }

    /// Selects `tab`, when it is ``ZenWindowTab/chat`` or an open sub-agent
    /// tab.
    public func selectTab(_ tab: ZenWindowTab) {
        guard tabs.contains(tab) else { return }
        setSelectedTab(tab)
    }

    /// Selects `tab` and tells every sub-agent model whether its tab is the
    /// selected one (``ZenSubAgentTranscriptModel/isSelected``).
    private func setSelectedTab(_ tab: ZenWindowTab) {
        if selectedTab != tab {
            selectedTab = tab
        }
        for model in subAgentTabs {
            let isSelected = tab == .subAgent(model.agentID)
            if model.isSelected != isSelected {
                model.isSelected = isSelected
            }
        }
    }

    /// Closes every sub-agent tab, stopping their models, and selects the
    /// conversation.
    func closeSubAgentTabs() {
        stopSubAgentTabs()
        if !subAgentTabs.isEmpty {
            subAgentTabs = []
        }
        setSelectedTab(.chat)
    }

    func stopSubAgentTabs() {
        for model in subAgentTabs {
            model.stop()
        }
    }
}
