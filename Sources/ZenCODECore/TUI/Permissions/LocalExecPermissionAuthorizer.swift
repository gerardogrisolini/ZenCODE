//
//  LocalExecPermissionAuthorizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenCODERuntime

/// Channel adapter of the terminal over the channel-neutral
/// ``ChatToolConsentAuthorizer``.
///
/// The consent policy (gated tools, cache, persistence, dialog queue) lives in
/// the shared authorizer. This adapter connects it to the terminal: it wires a
/// terminal consent host that renders the consent card and reads the
/// operator's key through the injected key reader, and it keeps the terminal
/// API and the `local.exec` identity/persistence helpers. It is not a
/// deprecated name: a host app that is not a terminal builds its own
/// ``ChatToolConsentAuthorizer`` with its own ``ChatInteractionHost`` instead.
public actor LocalExecPermissionAuthorizer {
    enum PermissionDecision: Sendable {
        case allowOnce
        case allowAlways
        case deny
    }

    /// Tool names this authorizer gates: shell commands plus the destructive
    /// direct tools. Everything else is pre-approved by tool selection.
    public static let gatedToolNames: Set<String> = ChatToolConsentAuthorizer.gatedToolNames

    /// The shared consent policy this terminal facade delegates to.
    nonisolated let consentAuthorizer: ChatToolConsentAuthorizer
    /// Terminal host behind ``consentAuthorizer``: it owns the injected reader.
    nonisolated let terminalHost: TerminalConsentHost

    public init() {
        let terminalHost = TerminalConsentHost()
        self.terminalHost = terminalHost
        self.consentAuthorizer = ChatToolConsentAuthorizer(host: terminalHost)
    }

    /// Injected single-key reader for consent prompts. When nil, the default
    /// terminal reader is used. The TUI sets this to route consent through its
    /// shared interactive reader (avoiding a second terminal input device),
    /// and tests set it for deterministic loop/EOF coverage.
    func setConsentReader(_ reader: ConsentKeyReader?) {
        terminalHost.setConsentReader(reader)
    }

    public func authorize(_ request: AgentToolAuthorizationRequest) async -> Bool {
        await consentAuthorizer.authorize(request)
    }

    /// Authorizes a request without ever attempting to acquire terminal input.
    ///
    /// This is intentionally separate from `authorize(_:)`: headless callers
    /// must retain persisted approvals and pre-approved tools, but a new gated
    /// request has no operator available to answer a consent dialog. Such a
    /// request is therefore denied with an actionable diagnostic rather than
    /// falling through to `/dev/tty`.
    public func authorizeNonInteractively(
        _ request: AgentToolAuthorizationRequest
    ) async -> Bool {
        await consentAuthorizer.nonInteractiveOutcome(for: request).isApproved
    }

    // MARK: - Policy

    // The `local.exec` policy is channel-neutral and lives in the runtime
    // (``LocalExecPermissionPolicy``); these keep the terminal adapter's names.

    static func persistedCommandPermissionIdentities(for command: String) -> [String] {
        LocalExecPermissionPolicy.persistedCommandPermissionIdentities(for: command)
    }

    static func isCommandPersistentlyAllowed(_ command: String) -> Bool {
        LocalExecPermissionPolicy.isCommandPersistentlyAllowed(command)
    }

    static func isCommandPersistentlyAllowed(
        _ command: String,
        permissions: AgentPermissionsManifest?
    ) -> Bool {
        LocalExecPermissionPolicy.isCommandPersistentlyAllowed(command, permissions: permissions)
    }

    static func localExecPermissionCacheIdentities(for command: String) -> [String] {
        LocalExecPermissionPolicy.localExecPermissionCacheIdentities(for: command)
    }

    static func permissionCacheKey(toolName: String, identity: String) -> String {
        LocalExecPermissionPolicy.permissionCacheKey(toolName: toolName, identity: identity)
    }
}
