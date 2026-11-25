//
//  ZenSubAgentTranscriptSource.swift
//  ZenApp
//
//  Where a sub-agent tab reads from: the snapshot stream and the transcript
//  of its agent, and the chat-actor reads behind them.
//

import Foundation
import Observation
import Synchronization
import ToolCore
import ZenCODECore

/// Where a sub-agent tab reads: the snapshots of the session's sub-agents and
/// the transcript of its agent.
struct ZenSubAgentTranscriptSource: Sendable {
    /// The snapshots of the session's sub-agents, now and after every change;
    /// `nil` when the session the tab belongs to is no longer the window's,
    /// so there is nothing more to follow.
    var snapshotEvents: @Sendable () async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>?
    /// The live transcript of the agent; `nil` when the session has no such
    /// agent, the agent's backend was shut down, the session has no backend,
    /// or it is no longer the window's.
    var transcript: @Sendable () async -> ChatSubAgentTranscript?

    /// The agent `agentID` of the incarnation `epoch` of `slotID`, read on
    /// the chat actor for that incarnation only: once the slot runs another
    /// session, both reads answer `nil`.
    static func incarnation(
        epoch: UInt64,
        agentID: String,
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID
    ) -> ZenSubAgentTranscriptSource {
        ZenSubAgentTranscriptSource(
            snapshotEvents: {
                await ZenSubAgentSteps.snapshotEvents(in: sessionHost, slotID: slotID, epoch: epoch)
            },
            transcript: {
                await ZenSubAgentSteps.transcript(agentID: agentID, in: sessionHost, slotID: slotID, epoch: epoch)
            }
        )
    }
}

/// The reads of a sub-agent tab on the chat actor, each for one incarnation.
@ChatSessionActor
enum ZenSubAgentSteps {
    /// The controller `slotID` runs now, when it is the one of `epoch`.
    static func controller(in sessionHost: ChatSessionHost, slotID: ChatSlotID, epoch: UInt64) -> ChatSessionController? {
        guard let incarnation = sessionHost.incarnation(in: slotID), incarnation.epoch == epoch else { return nil }
        return incarnation.controller
    }

    /// The snapshots of the sub-agents of the incarnation's session, from the
    /// slot's runner with the session as the root session.
    static func snapshotEvents(
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        epoch: UInt64
    ) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>? {
        guard let controller = controller(in: sessionHost, slotID: slotID, epoch: epoch),
              let runner = sessionHost.runner(in: slotID) else { return nil }
        return await runner.subAgentSnapshotEvents(rootSessionID: controller.sessionID)
    }

    static func transcript(
        agentID: String,
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        epoch: UInt64
    ) async -> ChatSubAgentTranscript? {
        guard let controller = controller(in: sessionHost, slotID: slotID, epoch: epoch) else { return nil }
        return await controller.subAgentTranscript(agentID: agentID)
    }
}
