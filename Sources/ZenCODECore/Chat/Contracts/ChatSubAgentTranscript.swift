//
//  ChatSubAgentTranscript.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/11/26.
//

import Foundation

/// The conversation of one delegated sub-agent, as the live history of its
/// backend holds it (see ``ChatSessionController/subAgentTranscript(agentID:)``).
///
/// The transcript is read from the agent's backend session when it is
/// requested, so it also shows the messages of a turn still running as the
/// backend records them. When the agent's backend is shut down (the agent was
/// closed, cancelled, failed, or released from standby) there is no history
/// left and the read returns `nil`. The Core keeps nothing: a caller that
/// wants to show the conversation after the agent ends keeps its last read.
///
/// The system prompt, the dynamic session context, and the automatic memory
/// block are not part of the history, so the transcript never contains them.
///
/// What the history does not keep is added for presentation only (see
/// ``DirectSubAgentRuntime/transcript(agentID:rootSessionID:)``): an assistant
/// message without reasoning shows the text of its `thinking` blocks as its
/// thought, and a tool call carries the title and the presentation of the
/// agent's own tool descriptor, so it is shown with its target.
public struct ChatSubAgentTranscript: Sendable, Equatable {
    /// The sub-agent the transcript belongs to.
    public let agentID: String
    /// The history as log entry kinds, oldest first, rebuilt the way a saved
    /// transcript is: a user prompt has an ``ChatTurnOrigin/unknown`` origin.
    public let kinds: [ChatTurnEntry.Kind]

    public init(agentID: String, kinds: [ChatTurnEntry.Kind]) {
        self.agentID = agentID
        self.kinds = kinds
    }
}
