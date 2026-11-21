//
//  ChatSessionController+SubAgents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/11/26.
//

import Foundation

// MARK: - Sub-agent transcripts

extension ChatSessionController {
    /// The live transcript of the sub-agent `agentID` of this controller's
    /// session (its ``sessionID`` is the root session the session's sub-agents
    /// are registered under): the agent's backend history now, in full.
    ///
    /// The read keeps no state (see ``ChatSubAgentTranscript``). `nil` when
    /// the session has no such agent (an unknown ID, an agent of another
    /// session, a terminal record already pruned), when the agent's backend
    /// was shut down (the agent ended), or when the session has no backend
    /// yet. Never creates a backend. A host that shows the conversation after
    /// the agent ends keeps its own last read.
    public func subAgentTranscript(agentID: String) async -> ChatSubAgentTranscript? {
        await runtime.subAgentTranscript(agentID: agentID, rootSessionID: sessionID)
    }
}
