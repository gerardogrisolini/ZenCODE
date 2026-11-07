//
//  ACPPromptPresenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Presents one ACP prompt turn as `session/update` notifications.
///
/// Bound to the prompt's update pipeline: every unit is fenced by that
/// prompt's presentation validity, so a cancelled turn that keeps unwinding
/// can never write into a newer prompt. Awaiting each unit preserves the
/// producer's backpressure while the pipeline fixes the wire order.
struct ACPPromptPresenter: ChatSessionPresenter {
    let sessionID: String
    /// ACP locations must be absolute: relative tool arguments are resolved
    /// against the session workspace, not the agent process directory.
    let workspaceURL: URL
    let writer: ACPWriter
    let updatePipeline: ACPPromptUpdatePipeline?
    /// Starts the taskless sub-agent observer before a tool call is shown.
    let ensureTasklessObserver: @Sendable () async -> Void
    /// Claims the delivery of one delegated tool notification (its tool call
    /// id and phase) for this prompt: `true` once per prompt, and only while
    /// the prompt holds its incarnation and presents its updates.
    let claimDelegatedToolNotification: @Sendable (String) async -> Bool
    /// The elapsed time of this prompt's root tool calls, for the title of
    /// their completion update; one per presenter, hence per prompt.
    var toolCallTimer = ACPToolCallTimer()

    private func send(_ update: JSONValue) async {
        if let updatePipeline {
            await updatePipeline.enqueue(.init(kind: .consume(update))).value
        } else {
            await writer.sendSessionUpdate(sessionID: sessionID, update: update)
        }
    }

    private func finishThought() async {
        if let updatePipeline {
            await updatePipeline.enqueue(.init(kind: .finishThought)).value
        }
    }

    func presentThought(_ thought: String) async {
        await send(ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_thought_chunk", text: thought))
    }

    func presentAssistantContent(_ content: String) async {
        await send(ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_message_chunk", text: content))
    }

    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {
        if let update = ZenCODEACPBridge.usageJSONUpdate(for: status) {
            await send(update)
        }
    }

    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {
        guard let subscriptionData = ZenCODEACPBridge.subscriptionUsageJSONData(for: status) else {
            return
        }
        // The custom notification bypasses the buffer. In app mode it must
        // share the serialized exit point with updates, as a flush-then-notify
        // unit; outside app mode there is no buffer and it goes straight out.
        let params = JSONValue.object([
            "sessionId": .string(sessionID),
            "subscription": subscriptionData,
        ])
        if let updatePipeline {
            await updatePipeline.enqueue(
                .init(kind: .flushThenNotify(method: "_zencode/usage/subscription", params: params))
            ).value
        } else {
            await writer.sendCustomNotification(method: "_zencode/usage/subscription", params: params)
        }
    }

    /// The call's `tool_call`; its elapsed time starts once it is sent, so
    /// the wire's backpressure is not part of it.
    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        await ensureTasklessObserver()
        await send(ZenCODEACPBridge.toolCallCreateJSONUpdate(for: toolCall, workingDirectory: workspaceURL))
        toolCallTimer.start(toolCall.id)
    }

    /// The call's completion `tool_call_update`, its title ending with the
    /// time elapsed since its `tool_call`; without a recorded start (a call
    /// cancelled before it was dispatched) the title has no time.
    func presentToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        let elapsed = toolCallTimer.complete(toolCall.id)
        await send(
            ZenCODEACPBridge.toolCallCompletionJSONUpdate(
                for: toolCall,
                result: result,
                workingDirectory: workspaceURL,
                elapsed: elapsed
            )
        )
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        await finishThought()
    }

    /// A delegated agent's tool call, as a `tool_call` when it starts and a
    /// `tool_call_update` when it completes, titled with the agent's name and
    /// sent once per call and phase while the prompt is current. A completion
    /// title ends with the time the sub-agent runtime measured
    /// (``DirectSubAgentToolEvent/elapsed``), when known.
    func presentSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        // Runtime agent IDs are unique per creation/attempt, and are also
        // available to the permission broker before any operation executes.
        let id = "acp:tool:\(event.agentID):\(event.toolCall.id)"
        var update: [String: Any]
        let phase: String
        let elapsed: Duration?
        switch event.lifecycle {
        case .started:
            phase = "started"
            elapsed = nil
            update = ZenCODEACPBridge.toolCallCreateUpdate(for: event.toolCall, workingDirectory: workspaceURL)
        case let .completed(result):
            phase = "completed"
            elapsed = event.elapsed
            update = ZenCODEACPBridge.toolCallCompletionUpdate(
                for: event.toolCall, result: result, workingDirectory: workspaceURL
            )
        }
        guard await claimDelegatedToolNotification(id + ":" + phase) else { return }
        update["toolCallId"] = id
        update["title"] = ZenCODEACPBridge.toolTitle(
            "\(event.agentName) — \(ZenCODEACPBridge.toolTitle(for: event.toolCall))",
            elapsed: elapsed
        )
        await send(JSONValue.acpValue(from: update))
    }

    /// Also covers backends that return without a turnEnded event, before an
    /// automatic workflow continuation starts a new model request.
    func modelTurnDidReturn() async {
        await finishThought()
    }

    /// The turn's reconciled file changes, as a final text block. ACP has no
    /// `/undo` or `/changes` command, so the command hint is omitted.
    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        await send(
            ZenCODEACPBridge.textChunkJSONUpdate(
                kind: "agent_message_chunk",
                text: TurnFileChangeSummaryPresentation.text(summary, includesCommandHint: false)
            )
        )
    }
}

/// Default presenter of an ACP session controller. ACP turns always supply
/// their prompt-bound ``ACPPromptPresenter``; nothing else is presented.
struct ACPSilentPresenter: ChatSessionPresenter {}
