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
/// left and the read returns `nil`. The Core keeps no copy of the history: a
/// caller that wants to show the conversation after the agent ends keeps its
/// last read.
///
/// The system prompt, the dynamic session context, and the automatic memory
/// block are not part of the history, so the transcript never contains them.
///
/// What the history does not keep is added for presentation only (see
/// ``DirectSubAgentRuntime/transcript(agentID:rootSessionID:)``): an assistant
/// message without reasoning shows the text of its `thinking` blocks as its
/// thought, and a tool call carries the title and the presentation of the
/// agent's own tool descriptor, so it is shown with its target.
///
/// The elapsed times of the tool calls (``toolDurations``) are not in the
/// history either: the runtime keeps the times the tool executor measured
/// (``DirectAgentToolResult/elapsed``), in memory only, for the agent's last
/// 512 calls. They are never saved.
public struct ChatSubAgentTranscript: Sendable, Equatable {
    /// The sub-agent the transcript belongs to.
    public let agentID: String
    /// The history as log entry kinds, oldest first, rebuilt the way a saved
    /// transcript is: a user prompt has an ``ChatTurnOrigin/unknown`` origin.
    public let kinds: [ChatTurnEntry.Kind]
    /// The elapsed time of the agent's completed tool calls, by tool call id
    /// (the `id` of the call in ``kinds``), as the tool executor measured it
    /// (``DirectAgentToolResult/elapsed``).
    ///
    /// A call that is still running, a call without an id, a call whose
    /// result the executor did not produce (cancelled before its dispatch),
    /// and a call older than the agent's last 512 have none. Every backend
    /// records a tool result in the history before it reports the
    /// completion, and the duration is recorded when the runtime handles that
    /// report, so ``kinds`` can briefly show a completed call whose duration
    /// a later read adds: a caller that shows the times compares them too,
    /// not only ``kinds``.
    public let toolDurations: [String: Duration]

    public init(
        agentID: String,
        kinds: [ChatTurnEntry.Kind],
        toolDurations: [String: Duration] = [:]
    ) {
        self.agentID = agentID
        self.kinds = kinds
        self.toolDurations = toolDurations
    }
}
