//
//  ACPPermissionBroker.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public actor ACPPermissionBroker {
    private let writer: ACPWriter
    private var alwaysAllowedKeys = Set<String>()
    private var alwaysRejectedKeys = Set<String>()
    private var decisionKeysBySessionID: [String: Set<String>] = [:]

    public init(writer: ACPWriter) {
        self.writer = writer
    }

    public func authorize(_ request: AgentToolAuthorizationRequest) async -> Bool {
        let cacheKey = permissionCacheKey(for: request)
        if alwaysAllowedKeys.contains(cacheKey) {
            return true
        }
        if alwaysRejectedKeys.contains(cacheKey) {
            return false
        }
        if request.toolName == "local.exec",
           LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(request.command) {
            return true
        }

        let optionID: String
        do {
            let result = try await writer.request(
                method: "session/request_permission",
                params: JSONValue.acpValue(from: permissionParams(for: request))
            )
            optionID = Self.permissionOptionID(from: result) ?? "reject_once"
        } catch {
            return false
        }

        if optionID == "allow_always" {
            alwaysAllowedKeys.insert(cacheKey)
            remember(cacheKey: cacheKey, for: request.sessionID)
            if request.toolName == "local.exec" {
                LocalExecPermissionAuthorizer.persistAllowedCommand(request.command)
            }
            return true
        }
        if optionID == "reject_always" {
            alwaysRejectedKeys.insert(cacheKey)
            remember(cacheKey: cacheKey, for: request.sessionID)
            return false
        }
        if optionID == "allow" || optionID.hasPrefix("allow_") {
            return true
        }
        return false
    }

    public func handleResponse(_ message: JSONValue) async {
        await writer.handleResponse(message)
    }

    public func removeCachedDecisions(sessionID: String) {
        guard let keys = decisionKeysBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        alwaysAllowedKeys.subtract(keys)
        alwaysRejectedKeys.subtract(keys)
    }

    public func removeAllCachedDecisions() {
        alwaysAllowedKeys.removeAll()
        alwaysRejectedKeys.removeAll()
        decisionKeysBySessionID.removeAll()
    }

    func cachedDecisionCount(sessionID: String) -> Int {
        decisionKeysBySessionID[sessionID]?.count ?? 0
    }

    private func remember(cacheKey: String, for rawSessionID: String?) {
        guard let sessionID = rawSessionID?.nilIfBlank else { return }
        decisionKeysBySessionID[sessionID, default: []].insert(cacheKey)
    }

    private func permissionParams(for request: AgentToolAuthorizationRequest) -> [String: Any] {
        let sessionID = request.sessionID ?? ""
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
                "toolCallId": request.toolCallID,
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

    private func permissionCacheKey(for request: AgentToolAuthorizationRequest) -> String {
        Self.permissionCacheKeyValue(for: request)
    }

    static func permissionCacheKeyValue(for request: AgentToolAuthorizationRequest) -> String {
        Self.lengthPrefixedComponents([
            request.sessionID ?? "",
            request.toolName,
            request.workingDirectory,
            Self.permissionCacheCommandIdentity(for: request)
        ])
    }

    static func permissionCacheCommandIdentity(
        for request: AgentToolAuthorizationRequest
    ) -> String {
        guard request.toolName == "local.exec" else {
            return request.command
        }
        let identities = LocalExecPermissionAuthorizer
            .localExecPermissionCacheIdentities(for: request.command)
        guard !identities.isEmpty else {
            return request.command
        }
        return Self.lengthPrefixedComponents(identities)
    }

    private static func lengthPrefixedComponents(_ components: [String]) -> String {
        "\(components.count):" + components.map {
            "\($0.utf8.count):\($0)"
        }.joined()
    }

    static func permissionOptionID(from result: JSONValue?) -> String? {
        if let optionID = result?.acpStringValue {
            return optionID
        }
        guard let object = result?.objectValue else {
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
