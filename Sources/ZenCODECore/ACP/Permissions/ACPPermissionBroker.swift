//
//  ACPPermissionBroker.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// Channel adapter of ACP over the channel-neutral ``ChatToolConsentAuthorizer``.
///
/// The consent policy (cache, persistence, teardown invalidation) lives in the
/// shared authorizer. This adapter connects it to ACP: it wires an
/// ``ACPConsentHost`` that asks the client with `session/request_permission`,
/// and it keeps the ACP API used by the bridge. It is not a deprecated name: a
/// host app that is not an ACP client builds its own
/// ``ChatToolConsentAuthorizer`` with its own ``ChatInteractionHost`` instead.
public actor ACPPermissionBroker {
    private let writer: ACPWriter
    /// The shared consent policy this ACP facade delegates to.
    nonisolated let consentAuthorizer: ChatToolConsentAuthorizer

    public init(writer: ACPWriter) {
        self.writer = writer
        self.consentAuthorizer = ChatToolConsentAuthorizer(
            host: ACPConsentHost(writer: writer)
        )
    }

    public func authorize(_ request: AgentToolAuthorizationRequest) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await consentAuthorizer.authorize(request)
    }

    public func handleResponse(_ message: JSONValue) async {
        await writer.handleResponse(message)
    }

    public func removeCachedDecisions(sessionID: String) async {
        await consentAuthorizer.removeCachedDecisions(sessionID: sessionID)
    }

    public func removeAllCachedDecisions() async {
        await consentAuthorizer.removeAllCachedDecisions()
    }

    func cachedDecisionCount(sessionID: String) async -> Int {
        await consentAuthorizer.cachedDecisionCount(sessionID: sessionID)
    }

    static func permissionCacheKeyValue(for request: AgentToolAuthorizationRequest) -> String {
        ChatToolConsentAuthorizer.permissionCacheKeyValue(for: request)
    }

    static func permissionCacheCommandIdentity(
        for request: AgentToolAuthorizationRequest
    ) -> String {
        ChatToolConsentAuthorizer.permissionCacheCommandIdentity(for: request)
    }

    static func permissionOptionID(from result: JSONValue?) -> String? {
        ACPConsentHost.permissionOptionID(from: result)
    }
}
