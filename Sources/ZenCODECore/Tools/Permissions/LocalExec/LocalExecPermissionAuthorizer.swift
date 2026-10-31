//
//  LocalExecPermissionAuthorizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// Terminal-facing facade over the channel-neutral ``ChatToolConsentAuthorizer``.
///
/// The consent policy (gated tools, cache, persistence, dialog queue) lives in
/// the shared authorizer; this type keeps the established terminal API and the
/// `local.exec` identity/persistence helpers, and wires a terminal host that
/// renders the consent card and reads the operator's key.
public actor LocalExecPermissionAuthorizer {
    enum PermissionDecision: Sendable {
        case allowOnce
        case allowAlways
        case deny
    }

    /// Detailed result used when another consent surface (for example Telegram)
    /// is presented at the same time. The public Boolean API intentionally keeps
    /// its existing fail-closed contract, while the coordinator must distinguish
    /// an explicit rejection from a terminal that is unavailable or cancelled.
    typealias AuthorizationOutcome = ChatToolConsentAuthorizer.AuthorizationOutcome

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

    /// Drops process-local authorization state so a completed setup run is
    /// reconciled from the current permissions manifest. This is especially
    /// important after setup reset removes that manifest.
    func reloadPersistedPermissions() async {
        await consentAuthorizer.reloadPersistedPermissions()
    }

    /// Returns `true` when this request needs no dialog: either the tool is not
    /// gated, or a previous decision already covers it.
    ///
    /// Surfaces that mirror the session elsewhere (Telegram) use this to avoid
    /// announcing a consent step that will never be presented.
    public func isAlreadyAuthorized(_ request: AgentToolAuthorizationRequest) async -> Bool {
        await consentAuthorizer.isAlreadyAuthorized(request)
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

    func authorizationOutcome(
        for request: AgentToolAuthorizationRequest
    ) async -> AuthorizationOutcome {
        await consentAuthorizer.authorizationOutcome(for: request)
    }

    /// Imports an "always" decision made on another consent surface into the
    /// terminal authorizer's session cache. This keeps later local and Telegram
    /// turns consistent even if Telegram is disabled after the decision.
    func recordAlwaysAuthorization(for request: AgentToolAuthorizationRequest) async {
        await consentAuthorizer.recordAlwaysDecision(for: request)
    }

    static func commandPermissionIdentities(for command: String) -> [String] {
        LocalExecCommandParser.authorizationCandidates(in: command).map(\.identity)
    }

    static func commandPermissionIdentity(for command: String) -> String? {
        // Use the shared parser's structured candidates: the identity is the
        // first authorizable executable. Harmless built-ins/keywords, comments,
        // and decorative echo/printf are filtered so that e.g. `pwd && rm -rf tmp`
        // yields `rm` rather than the inert `pwd`.
        commandPermissionIdentities(for: command).first
    }

    static func persistedCommandPermissionIdentities(for command: String) -> [String] {
        commandPermissionIdentities(for: command)
    }

    static func persistedCommandPermissionIdentity(for command: String) -> String? {
        persistedCommandPermissionIdentities(for: command).first
    }

    static func isCommandPersistentlyAllowed(
        _ command: String,
        permissions: AgentPermissionsManifest? = persistedPermissions()
    ) -> Bool {
        let commandIdentities = persistedCommandPermissionIdentities(for: command)
        guard !commandIdentities.isEmpty,
              !commandIdentities.contains(where: LocalExecCommandParser.isNonPersistableIdentity),
              let permissions else {
            return false
        }
        return commandIdentities.allSatisfy(permissions.containsLocalExecAllowedCommand)
    }

    static func persistAllowedCommand(_ command: String) {
        let commandIdentities = persistedCommandPermissionIdentities(for: command)
        guard !commandIdentities.isEmpty else {
            return
        }
        persistAllowedCommandIdentities(commandIdentities)
    }

    static func localExecPermissionCacheIdentities(for command: String) -> [String] {
        persistedCommandPermissionIdentities(for: command).map { identity in
            guard LocalExecCommandParser.isNonPersistableIdentity(identity) else {
                return identity
            }
            // NUL cannot occur in a POSIX executable name. Scoping the fallback
            // to the full command prevents it from authorizing a different,
            // unanalyzed tail while still allowing an exact in-memory repeat.
            return "\(identity)\0\(command)"
        }
    }

    /// Builds a case-insensitive cache key for ordinary executable identities.
    /// A non-persistable parser fallback embeds the full original
    /// command after a NUL and deliberately retains its exact case: executable
    /// names may be case-sensitive, particularly on Linux.
    static func permissionCacheKey(toolName: String, identity: String) -> String {
        let identityParts = identity.split(
            separator: "\0",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let isExactFallback = identityParts.count == 2
            && LocalExecCommandParser.isNonPersistableIdentity(String(identityParts[0]))
        let normalizedIdentity: String
        if isExactFallback {
            normalizedIdentity = identity
        } else {
            // Persisted executable identities are matched case-insensitively.
            normalizedIdentity = identity.lowercased()
        }
        return Self.lengthPrefixedComponents([toolName, normalizedIdentity])
    }

    private static func lengthPrefixedComponents(_ components: [String]) -> String {
        "\(components.count):" + components.map {
            "\($0.utf8.count):\($0)"
        }.joined()
    }

    private static func persistAllowedCommandIdentities(_ commandIdentities: [String]) {
        do {
            _ = try AgentPermissionsManifestStore
                .appendingLocalExecAllowedCommandIdentities(commandIdentities)
        } catch {
            return
        }
    }

    private static func persistedPermissions() -> AgentPermissionsManifest? {
        let permissions = AgentPermissionsManifestStore.load()
        let legacyCommands = AgentSettingsManifestStore.load()?.localExecAllowedCommands ?? []
        guard permissions != nil || !legacyCommands.isEmpty else {
            return nil
        }

        let legacyIdentities = legacyCommands.flatMap {
            persistedCommandPermissionIdentities(for: $0)
        }
        let migrated = (permissions ?? AgentPermissionsManifest())
            .appendingLocalExecAllowedCommandIdentities(
                legacyIdentities
            )
        if migrated != permissions {
            do {
                return try AgentPermissionsManifestStore
                    .appendingLocalExecAllowedCommandIdentities(legacyIdentities)
            } catch {
                ZenLogger.warning(
                    .diagnostics,
                    "Failed to persist migrated local-exec permissions: \(error.localizedDescription)"
                )
            }
        }
        return migrated
    }
}
