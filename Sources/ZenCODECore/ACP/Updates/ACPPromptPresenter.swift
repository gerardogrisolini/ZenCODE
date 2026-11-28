//
//  ACPPromptPresenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization
import ToolCore
import ZenCODERuntime

/// The tool calls a presenter already wrote to the client, by id.
///
/// ACP relates a `tool_call_update` to the `tool_call` of the same id, so a
/// completion for a call whose creation never reached the client (a call
/// cancelled before it was shown) writes the creation first. Only
/// presentation state: nothing of it is persisted.
struct ACPPresentedToolCalls: Sendable {
    private final class Storage: Sendable {
        let ids = Mutex<Set<String>>(Set())
    }

    private let storage = Storage()

    /// Registers `id` and tells whether the client had not received its
    /// `tool_call` yet.
    func markPresented(_ id: String) -> Bool {
        storage.ids.withLock { $0.insert(id).inserted }
    }

    /// `true` while the client received the `tool_call` of `id`.
    func contains(_ id: String) -> Bool {
        storage.ids.withLock { $0.contains(id) }
    }
}

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
    /// Closes the row of a delegated tool call a permission request announced
    /// (``ZenCODEACPBridge/completeDelegatedPermissionToolCall(_:sessionID:)``);
    /// any other delegated call writes nothing.
    let completeDelegatedToolCall: @Sendable (DirectSubAgentToolEvent) async -> Void
    /// The tool calls this turn already showed, by id.
    private let presentedToolCalls = ACPPresentedToolCalls()

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

    /// The chunks of thought and of the model's text are written without a
    /// `messageId`: the turn's update pipeline, which sees every update of the
    /// turn in order, gives each the id of the message it belongs to (see
    /// ``ACPPromptUpdatePipeline``).
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

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        await ensureTasklessObserver()
        _ = presentedToolCalls.markPresented(toolCall.id)
        await send(ZenCODEACPBridge.toolCallCreateJSONUpdate(for: toolCall, workingDirectory: workspaceURL))
    }

    /// The call's completion `tool_call_update`: its final status and result
    /// as `content`, with no `title` (the one of the `tool_call` stays). A
    /// completion of a call the client never saw — the turn was cancelled
    /// before its creation was written — is preceded by the `tool_call` it
    /// refers to.
    func presentToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        if presentedToolCalls.markPresented(toolCall.id) {
            await send(
                ZenCODEACPBridge.toolCallCreateJSONUpdate(
                    for: toolCall,
                    workingDirectory: workspaceURL
                )
            )
        }
        await send(
            ZenCODEACPBridge.toolCallCompletionJSONUpdate(
                for: toolCall,
                result: result,
                workingDirectory: workspaceURL
            )
        )
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        await finishThought()
    }

    /// A delegated agent's tool call is not presented in the session: as in
    /// `codex-acp` without a sub-agent contract, the client sees the agent as
    /// one tool call (``ACPTaskPresentation``, ``ACPTasklessPresentation``),
    /// not the calls the agent makes. The one exception is a call a permission
    /// request announced to the client, whose completion closes its row
    /// (``completeDelegatedToolCall``).
    func presentSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        guard case .completed = event.lifecycle else { return }
        await completeDelegatedToolCall(event)
    }

    /// Also covers backends that return without a turnEnded event, before an
    /// automatic workflow continuation starts a new model request.
    func modelTurnDidReturn() async {
        await finishThought()
    }

    /// Writes nothing: the controller reports the Summary while the turn is
    /// still running, before the turn's final plan, and the Summary must be
    /// the last text section of the turn. The bridge presents it once the turn
    /// has ended, from ``ChatTurnResult/fileChangeSummary`` or
    /// ``ChatTurnFailure/fileChangeSummary``, after the final plan and before
    /// the reply of the prompt
    /// (``ZenCODEACPBridge/publishFileChangeSummary(_:for:pipeline:)``).
    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {}
}

/// Default presenter of an ACP session controller. ACP turns always supply
/// their prompt-bound ``ACPPromptPresenter``; nothing else is presented, but
/// the completion of a delegated tool call a permission request announced
/// while no prompt presents it (the prompt ended or was cancelled while the
/// agent kept working), which closes the call's row
/// (``ZenCODEACPBridge/completeDelegatedPermissionToolCall(_:sessionID:)``).
struct ACPSilentPresenter: ChatSessionPresenter {
    var completeDelegatedToolCall: (@Sendable (DirectSubAgentToolEvent) async -> Void)?

    func presentSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        guard case .completed = event.lifecycle else { return }
        await completeDelegatedToolCall?(event)
    }
}
