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
struct ACPConsentHost: ChatInteractionHost {
    private let writer: ACPWriter

    init(writer: ACPWriter) {
        self.writer = writer
    }

    var capabilities: ChatChannelCapabilities {
        [.toolConsent]
    }

    func requestToolConsent(
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

    private static func permissionParams(
        for request: AgentToolAuthorizationRequest
    ) -> [String: Any] {
        let sessionID = request.delegatedIdentity?.rootSessionID ?? request.sessionID ?? ""
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
            "toolCall": [
                "toolCallId": request.delegatedIdentity.map { "acp:tool:\($0.agentID):\(request.toolCallID)" } ?? request.toolCallID,
                "status": "pending",
                "title": request.title,
                "kind": ZenCODEACPBridge.acpToolKind(request.kind),
                "content": [
                    [
                        "type": "content",
                        "content": [
                            "type": "text",
                            "text": """
                            Directory:
                            \(request.workingDirectory)

                            Command:
                            \(request.command)
                            """
                        ]
                    ]
                ],
                "locations": [
                    [
                        "path": request.workingDirectory
                    ]
                ],
                "_meta": [
                    "rawInput": [
                        "command": request.command,
                        "description": "Run shell command in \(request.workingDirectory)",
                        "workingDirectory": request.workingDirectory
                    ]
                ]
            ]
        ]
    }

    /// The selected option ID of a permission reply, or `nil` when the reply
    /// names none (a cancellation among them).
    static func permissionOptionID(from result: JSONValue?) -> String? {
        guard let object = result?.objectValue else {
            return result?.acpStringValue
        }
        return selectedOptionID(in: object)
            ?? object["outcome"]?.objectValue.flatMap { selectedOptionID(in: $0) }
            ?? object["selected"]?.objectValue.flatMap { selectedOptionID(in: $0) }
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
        if let optionID = permissionOptionID(from: result) {
            return .option(optionID)
        }
        guard let object = result?.objectValue else {
            return .unknown
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
