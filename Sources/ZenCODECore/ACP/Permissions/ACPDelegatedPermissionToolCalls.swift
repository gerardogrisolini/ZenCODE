//
//  ACPDelegatedPermissionToolCalls.swift
//  ZenCODE
//
//  The delegated tool calls a permission request announces to the client.
//
//  A delegated agent's tool calls are not presented in the session that owns
//  the agent: as `codex-acp` does without a sub-agent contract, the client
//  sees the agent's lifecycle as one ordinary tool call (the rows of
//  `ACPTaskPresentation` and `ACPTasklessPresentation`). A call that asks the
//  operator's consent is the exception: the permission stays on the root
//  session and must refer to a call the client knows, so the session's
//  consent host announces it with a `tool_call` right before the
//  `session/request_permission`. The root session reports these transitions
//  while it receives the delegated tool events:
//
//  - refused, dismissed, or not answered: a `tool_call_update` with
//    `status: failed`;
//  - allowed: a `tool_call_update` with `status: in_progress` (the tool is
//    about to run), then the completion of the delegated tool, the ordinary
//    completing `tool_call_update` (status and content), closes it.
//
//  The ids of the calls announced and not yet final belong to the session's
//  incarnation (`SessionState.delegatedPermissionToolCalls`), not to a
//  prompt: a sub-agent keeps working after the prompt that started it ended
//  or was cancelled, and its permission and completion may arrive then. Every
//  update is written only for an id of that set, so no `tool_call_update` is
//  ever written for a call the client was not announced, and a new
//  incarnation of the same session id (which starts with an empty set) never
//  receives an update of an older one. The writes go to the writer directly,
//  as the permission request does, not through the prompt's pipeline, whose
//  admission ends with the prompt; while a prompt presents, its pipeline is
//  flushed first, so the text it buffered keeps its place before the call.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// What the consent host of an ACP session does around the permission request
/// of a delegated agent's tool call (see ``ACPConsentHost``).
struct ACPDelegatedPermissionPresentation: Sendable {
    /// Announces the call with a `tool_call`, before the request is written.
    let announce: @Sendable (AgentToolAuthorizationRequest) async -> Void
    /// Gives the announced call the state the operator's answer implies.
    let settle: @Sendable (AgentToolAuthorizationRequest, ChatConsentDecision?) async -> Void
}

extension ZenCODEACPBridge {
    /// The ACP id of the tool call `toolCallID` of the delegated agent
    /// `agentID`: runtime agent ids are unique per creation, and both the
    /// permission request and the tool's completion know them.
    static func delegatedToolCallID(agentID: String, toolCallID: String) -> String {
        "acp:tool:\(agentID):\(toolCallID)"
    }

    /// The presentation the consent host of an ACP session runs around a
    /// delegated permission request.
    func delegatedPermissionPresentation() -> ACPDelegatedPermissionPresentation {
        ACPDelegatedPermissionPresentation(
            announce: { [weak self] request in
                await self?.announceDelegatedPermissionToolCall(request)
            },
            settle: { [weak self] request, decision in
                await self?.settleDelegatedPermissionToolCall(request, decision: decision)
            }
        )
    }

    /// Writes the `tool_call` of the delegated call `request` is about to the
    /// live session of its root, once: a second request for a call already
    /// announced writes nothing. A session that is not live is announced
    /// nothing, and its permission request is asked as it always was.
    func announceDelegatedPermissionToolCall(_ request: AgentToolAuthorizationRequest) async {
        guard let identity = request.delegatedIdentity, !isShutDown else { return }
        let sessionID = identity.rootSessionID
        let id = Self.delegatedToolCallID(agentID: identity.agentID, toolCallID: request.toolCallID)
        guard let epoch = sessions[sessionID]?.epoch,
              sessions[sessionID]?.delegatedPermissionToolCalls.insert(id).inserted == true else { return }
        await writeDelegatedPermissionToolCallUpdate(
            JSONValue.acpValue(from: ACPConsentHost.delegatedToolCallAnnouncement(for: request)),
            sessionID: sessionID,
            epoch: epoch,
            owedCallID: id
        )
    }

    /// Gives the announced call of `request` the state `decision` implies:
    /// `in_progress` when the operator allowed it (its completion closes it,
    /// ``completeDelegatedPermissionToolCall(_:sessionID:)``), `failed` and
    /// final otherwise (refused, dismissed, or not answered). Nothing for a
    /// call this incarnation did not announce.
    func settleDelegatedPermissionToolCall(
        _ request: AgentToolAuthorizationRequest,
        decision: ChatConsentDecision?
    ) async {
        guard let identity = request.delegatedIdentity else { return }
        let sessionID = identity.rootSessionID
        let id = Self.delegatedToolCallID(agentID: identity.agentID, toolCallID: request.toolCallID)
        guard let epoch = sessions[sessionID]?.epoch,
              sessions[sessionID]?.delegatedPermissionToolCalls.contains(id) == true else { return }
        let isAllowed: Bool
        switch decision {
        case .allowOnce, .allowAlways:
            isAllowed = true
        case .denyOnce, .denyAlways, nil:
            // Final: the completion that follows the refusal writes nothing.
            sessions[sessionID]?.delegatedPermissionToolCalls.remove(id)
            isAllowed = false
        }
        await writeDelegatedPermissionToolCallUpdate(
            .object([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string(id),
                "status": .string(isAllowed ? "in_progress" : "failed"),
            ]),
            sessionID: sessionID,
            epoch: epoch,
            owedCallID: isAllowed ? id : nil
        )
    }

    /// Closes the row of the delegated call of `event`, a completion, when a
    /// permission request of the live incarnation of `sessionID` announced it
    /// and it is not final yet: the ordinary completing `tool_call_update`
    /// (``toolCallCompletionUpdate(for:result:workingDirectory:)``, its status
    /// and its result as content) with the delegated id. Every other
    /// delegated event writes nothing. The prompt's presenter and the
    /// session's own (outside a prompt, or after its cancellation) both route
    /// completions here, and the first one closes the row.
    func completeDelegatedPermissionToolCall(_ event: DirectSubAgentToolEvent, sessionID: String) async {
        guard case let .completed(result) = event.lifecycle, !isShutDown else { return }
        let id = Self.delegatedToolCallID(agentID: event.agentID, toolCallID: event.toolCall.id)
        guard let session = sessions[sessionID],
              sessions[sessionID]?.delegatedPermissionToolCalls.remove(id) != nil else { return }
        var update = Self.toolCallCompletionUpdate(
            for: event.toolCall,
            result: result,
            workingDirectory: URL(fileURLWithPath: session.cwd)
        )
        update["toolCallId"] = id
        await writeDelegatedPermissionToolCallUpdate(
            JSONValue.acpValue(from: update),
            sessionID: sessionID,
            epoch: session.epoch,
            owedCallID: nil
        )
    }

    /// Writes `update`, of a delegated call of the incarnation `epoch` of
    /// `sessionID`, after the text the prompt presenting the session now has
    /// buffered. The flush may suspend, so the update is written only while
    /// the transport is open, that incarnation is still the live one, and,
    /// with an `owedCallID`, it still owes that call a final state (a final
    /// update, which already took the id, passes `nil`).
    private func writeDelegatedPermissionToolCallUpdate(
        _ update: JSONValue,
        sessionID: String,
        epoch: UInt64,
        owedCallID: String?
    ) async {
        if let pipeline = sessions[sessionID]?.promptUpdatePipeline {
            await pipeline.enqueue(.init(kind: .flush)).value
        }
        guard !isShutDown,
              let session = sessions[sessionID],
              session.epoch == epoch else { return }
        if let owedCallID {
            guard session.delegatedPermissionToolCalls.contains(owedCallID) else { return }
        }
        await writer.sendSessionUpdate(sessionID: sessionID, update: update)
    }
}
