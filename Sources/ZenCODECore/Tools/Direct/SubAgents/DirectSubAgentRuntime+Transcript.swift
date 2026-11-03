//
//  DirectSubAgentRuntime+Transcript.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/11/26.
//

import Foundation

extension DirectSubAgentRuntime {
    /// The live transcript of the agent `agentID` of the root session
    /// `rootSessionID`, oldest first: its backend's current history, read in
    /// full, so the transcript of a running turn grows as the backend records
    /// it.
    ///
    /// The read keeps no state: the runtime stores no copy of the history.
    /// `nil` when no such agent exists, it belongs to another root session,
    /// or its backend no longer has the agent's session (the backend was shut
    /// down: the agent was closed, cancelled, failed, or released from
    /// standby). A caller that wants to show the conversation after the agent
    /// ends keeps its own last read.
    public func transcript(
        agentID: String,
        rootSessionID: String
    ) async -> ChatSubAgentTranscript? {
        guard let agent = agents[agentID],
              agent.rootSessionID == rootSessionID,
              let history = await agent.backend.snapshotSession(id: agent.sessionID)?.history else {
            return nil
        }
        // Actor reentrancy: while the backend was read the agent may have been
        // pruned or its record replaced. Decide on the record as it is after
        // the suspension.
        guard let current = agents[agentID],
              current.rootSessionID == rootSessionID else {
            return nil
        }
        return ChatSubAgentTranscript(
            agentID: agentID,
            kinds: ChatTurnEntry.kinds(fromTranscript: history)
        )
    }
}
