//
//  ACPConsentHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

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
        let optionID: String
        do {
            let result = try await writer.request(
                method: "session/request_permission",
                params: JSONValue.acpValue(from: Self.permissionParams(for: request))
            )
            optionID = Self.permissionOptionID(from: result) ?? "reject_once"
        } catch {
            return nil
        }

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

    static func permissionOptionID(from result: JSONValue?) -> String? {
        if let optionID = result?.acpStringValue {
            return optionID
        }
        guard let object = result?.objectValue else {
            return nil
        }
        // Cancellation wins over contradictory legacy selection fields.
        if object["outcome"]?.acpStringValue == "cancelled"
            || object["outcome"]?.objectValue?["outcome"]?.acpStringValue == "cancelled"
            || object["selected"]?.objectValue?["outcome"]?.acpStringValue == "cancelled" {
            return nil
        }
        if let optionID = selectedOptionID(in: object) {
            return optionID
        }
        if let outcome = object["outcome"]?.objectValue,
           let optionID = selectedOptionID(in: outcome) {
            return optionID
        }
        if let selected = object["selected"]?.objectValue,
           let optionID = selectedOptionID(in: selected) {
            return optionID
        }
        return nil
    }

    private static func selectedOptionID(in object: [String: JSONValue]) -> String? {
        object["optionId"]?.acpStringValue
            ?? object["optionID"]?.acpStringValue
            ?? object["option_id"]?.acpStringValue
            ?? object["confirmKey"]?.acpStringValue
            ?? object["confirm_key"]?.acpStringValue
    }
}
