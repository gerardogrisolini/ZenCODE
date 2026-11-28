//
//  ACPConsentHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// ACP implementation of the consent host: asks the client with a
/// `session/request_permission` request and maps the selected option.
///
/// The client renders its own UI, so dialogs are not serialized here and the
/// host only declares ``ChatChannelCapabilities/toolConsent``.
///
/// A delegated agent's tool calls are not presented in the session, so the
/// host of an ACP session (``delegatedPresentation``) announces the call a
/// delegated request is about with a `tool_call` before asking, and gives it
/// the state the answer implies afterwards (see
/// `ACPDelegatedPermissionToolCalls.swift`): the request then refers to a call
/// the client knows. The broker's own host, which asks only for a session no
/// slot runs, has none and asks as it always did.
struct ACPConsentHost: ChatInteractionHost {
    private let writer: ACPWriter
    private let delegatedPresentation: ACPDelegatedPermissionPresentation?

    init(writer: ACPWriter, delegatedPresentation: ACPDelegatedPermissionPresentation? = nil) {
        self.writer = writer
        self.delegatedPresentation = delegatedPresentation
    }

    var capabilities: ChatChannelCapabilities {
        [.toolConsent]
    }

    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        // A cancelled request is never written (see `ACPWriter.request`), so
        // there is no call to announce either.
        guard !Task.isCancelled else { return nil }
        let delegated = request.delegatedIdentity == nil ? nil : delegatedPresentation
        await delegated?.announce(request)
        let decision = await askClient(request)
        await delegated?.settle(request, decision)
        return decision
    }

    private func askClient(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        let result: JSONValue?
        do {
            result = try await writer.request(
                method: "session/request_permission",
                params: JSONValue.acpValue(from: Self.permissionParams(for: request))
            )
        } catch {
            return nil
        }

        switch Self.permissionOutcome(from: result) {
        case let .option(optionID):
            switch optionID {
            case "allow_once":
                return .allowOnce
            case "allow_always":
                return .allowAlways
            case "reject_always":
                return .denyAlways
            default:
                return .denyOnce
            }
        case .cancelled:
            // The operator dismissed the request: no decision, never a refusal
            // the model would read as the operator saying no.
            return nil
        case .unknown:
            // A reply the agent cannot read is not evidence of consent.
            return .denyOnce
        }
    }

    /// The `session/request_permission` params. The `toolCall` carries standard
    /// ACP v1 fields only (no `_meta`): `kind`, `status: pending`, a readable
    /// `title`, and `rawInput`.
    ///
    /// The title of a shell command is the bare command, as clients use it as
    /// the command label; every other request keeps its own readable title
    /// (`Delete /x`, `Push to remote`). No title names a delegated agent: the
    /// agent that asks is named in the `content` (`Requested by <agent>`).
    ///
    /// `rawInput` is `command`, `workingDirectory`, and `description`. The
    /// request does not carry the arguments of the original tool call, so for
    /// a tool other than the shell `command` is the operation the runtime
    /// described for consent (for instance `git push origin main`).
    static func permissionParams(
        for request: AgentToolAuthorizationRequest
    ) -> [String: Any] {
        let sessionID = request.delegatedIdentity?.rootSessionID ?? request.sessionID ?? ""
        var toolCall = toolCallFields(for: request)
        toolCall["status"] = "pending"
        toolCall["content"] = [
            [
                "type": "content",
                "content": [
                    "type": "text",
                    "text": permissionText(for: request)
                ]
            ]
        ]
        return [
            "sessionId": sessionID,
            "options": [
                [
                    "optionId": "allow_once",
                    "name": "Allow Once",
                    "kind": "allow_once"
                ],
                [
                    "optionId": "allow_always",
                    "name": "Allow Always",
                    "kind": "allow_always"
                ],
                [
                    "optionId": "reject_once",
                    "name": "Reject",
                    "kind": "reject_once"
                ],
                [
                    "optionId": "reject_always",
                    "name": "Reject Always",
                    "kind": "reject_always"
                ]
            ],
            "toolCall": toolCall
        ]
    }

    /// The `tool_call` that announces the call of a delegated `request` right
    /// before its permission request: the fields of the request's `toolCall`
    /// (id, title, kind, locations, `rawInput`), the programmatic tool `name`,
    /// `status: pending`, and no content yet, as a call starts.
    static func delegatedToolCallAnnouncement(
        for request: AgentToolAuthorizationRequest
    ) -> [String: Any] {
        var update = toolCallFields(for: request)
        update["sessionUpdate"] = "tool_call"
        update["name"] = request.toolName
        update["status"] = "pending"
        update["content"] = [Any]()
        return update
    }

    /// The ACP id of the tool call `request` is about: the agent and the call
    /// for a delegated agent (``ZenCODEACPBridge/delegatedToolCallID(agentID:toolCallID:)``),
    /// the call's own id otherwise.
    static func toolCallID(for request: AgentToolAuthorizationRequest) -> String {
        guard let identity = request.delegatedIdentity else { return request.toolCallID }
        return ZenCODEACPBridge.delegatedToolCallID(
            agentID: identity.agentID,
            toolCallID: request.toolCallID
        )
    }

    /// What the permission's `toolCall` and the announcing `tool_call` share.
    private static func toolCallFields(
        for request: AgentToolAuthorizationRequest
    ) -> [String: Any] {
        [
            "toolCallId": toolCallID(for: request),
            "title": permissionTitle(for: request),
            "kind": ZenCODEACPBridge.acpToolKind(request.kind),
            "locations": [
                [
                    "path": request.workingDirectory
                ]
            ],
            "rawInput": [
                "command": request.command,
                "description": "Run shell command in \(request.workingDirectory)",
                "workingDirectory": request.workingDirectory
            ]
        ]
    }

    private static func permissionTitle(for request: AgentToolAuthorizationRequest) -> String {
        guard request.kind == "execute",
              let command = request.command.nilIfBlank else {
            return request.titleWithoutDelegatedAgent
        }
        return command
    }

    /// The text of the request: the delegated agent that asks, when one does,
    /// then the directory and the command.
    private static func permissionText(for request: AgentToolAuthorizationRequest) -> String {
        let operation = """
        Directory:
        \(request.workingDirectory)

        Command:
        \(request.command)
        """
        guard let identity = request.delegatedIdentity else { return operation }
        let agent = request.delegatedAgentName?.nilIfBlank ?? identity.agentID
        return "Requested by \(agent)\n\n" + operation
    }

    /// The selected option ID of a permission reply, or `nil` when the reply
    /// names none (a cancellation among them).
    static func permissionOptionID(from result: JSONValue?) -> String? {
        if case let .option(optionID) = permissionOutcome(from: result) {
            return optionID
        }
        return nil
    }

    /// What a permission reply says: the option the operator chose, an explicit
    /// cancellation, or a reply the agent cannot read.
    enum PermissionOutcome: Equatable {
        case option(String)
        /// The client answered the request with a cancellation outcome.
        case cancelled
        /// No option and no cancellation: malformed or empty.
        case unknown
    }

    /// Reads a permission reply, keeping the cancellation ACP defines apart
    /// from a reply that names no option: the first is the operator dismissing
    /// the request, the second is a reply the agent cannot trust.
    static func permissionOutcome(from result: JSONValue?) -> PermissionOutcome {
        guard let object = result?.objectValue else {
            return result?.acpStringValue.map { .option($0) } ?? .unknown
        }
        // Cancellation wins over contradictory legacy selection fields.
        let outcomes = [
            object["outcome"],
            object["outcome"]?.objectValue?["outcome"],
            object["selected"]?.objectValue?["outcome"],
        ]
        if outcomes.contains(where: { $0?.acpStringValue == "cancelled" }) {
            return .cancelled
        }
        if let optionID = selectedOptionID(in: object)
            ?? object["outcome"]?.objectValue.flatMap({ selectedOptionID(in: $0) })
            ?? object["selected"]?.objectValue.flatMap({ selectedOptionID(in: $0) }) {
            return .option(optionID)
        }
        return .unknown
    }

    private static func selectedOptionID(in object: [String: JSONValue]) -> String? {
        object["optionId"]?.acpStringValue
            ?? object["optionID"]?.acpStringValue
            ?? object["option_id"]?.acpStringValue
            ?? object["confirmKey"]?.acpStringValue
            ?? object["confirm_key"]?.acpStringValue
    }
}
