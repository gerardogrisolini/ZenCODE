//
//  LocalExecPermissionAuthorizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public actor LocalExecPermissionAuthorizer {
    enum PermissionDecision: Sendable {
        case allowOnce
        case allowAlways
        case deny
    }

    private var alwaysAllowedKeys = Set<String>()
    private var didLoadPersistedAllowedCommands = false

    /// Tool names this authorizer gates: shell commands plus the destructive
    /// direct tools. Everything else is pre-approved by tool selection.
    public static let gatedToolNames: Set<String> =
        DirectToolExecutor.destructiveGatedToolNames.union(["local.exec"])

    public init() {}

    public func authorize(_ request: AgentToolAuthorizationRequest) async -> Bool {
        guard Self.gatedToolNames.contains(request.toolName) else {
            return true
        }

        #if !os(macOS)
        return true
        #else
        loadPersistedAllowedCommandsIfNeeded()
        let cacheKey = permissionCacheKey(for: request)
        if alwaysAllowedKeys.contains(cacheKey) {
            return true
        }

        guard let decision = await presentDialog(for: request) else {
            return false
        }

        switch decision {
        case .allowOnce:
            return true
        case .allowAlways:
            alwaysAllowedKeys.insert(cacheKey)
            // Only shell command identities are persisted across sessions;
            // destructive tool approvals live for the current process only.
            if request.toolName == "local.exec" {
                persistAllowedCommand(for: request)
            }
            return true
        case .deny:
            return false
        }
        #endif
    }

    static func commandPermissionIdentity(for command: String) -> String? {
        // Use the shared parser's structured candidates: the identity is the
        // first authorizable executable. Harmless built-ins/keywords, comments,
        // and decorative echo/printf are filtered so that e.g. `pwd && rm -rf tmp`
        // yields `rm` rather than the inert `pwd`.
        LocalExecCommandParser.authorizationCandidates(in: command).first?.identity
    }

    static func persistedCommandPermissionIdentity(for command: String) -> String? {
        commandPermissionIdentity(for: command)
    }

    static func isCommandPersistentlyAllowed(
        _ command: String,
        permissions: AgentPermissionsManifest? = persistedPermissions()
    ) -> Bool {
        guard let commandIdentity = persistedCommandPermissionIdentity(for: command),
              let permissions else {
            return false
        }
        return permissions.containsLocalExecAllowedCommand(commandIdentity)
    }

    static func persistAllowedCommand(_ command: String) {
        guard let commandIdentity = persistedCommandPermissionIdentity(for: command) else {
            return
        }
        persistAllowedCommandIdentity(commandIdentity)
    }

    private func permissionCacheKey(for request: AgentToolAuthorizationRequest) -> String {
        let identity = Self.persistedCommandPermissionIdentity(for: request.command)
            ?? request.command
        return Self.permissionCacheKey(toolName: request.toolName, identity: identity)
    }

    /// Builds a case-insensitive cache key. The persisted manifest matches
    /// command identities case-insensitively, so the in-memory cache must do
    /// the same to stay consistent across the dialog, ACP, and Telegram paths.
    private static func permissionCacheKey(toolName: String, identity: String) -> String {
        [toolName, identity.lowercased()].joined(separator: "\u{1f}")
    }

    private func loadPersistedAllowedCommandsIfNeeded() {
        guard !didLoadPersistedAllowedCommands else {
            return
        }
        didLoadPersistedAllowedCommands = true
        guard let permissions = Self.persistedPermissions() else {
            return
        }
        alwaysAllowedKeys.formUnion(
            permissions.localExecAllowedCommands.map {
                Self.permissionCacheKey(toolName: "local.exec", identity: $0)
            }
        )
    }

    private func persistAllowedCommand(for request: AgentToolAuthorizationRequest) {
        guard let commandIdentity = Self.persistedCommandPermissionIdentity(for: request.command) else {
            return
        }
        Self.persistAllowedCommandIdentity(commandIdentity)
    }

    private static func persistAllowedCommandIdentity(_ commandIdentity: String) {
        let permissions = persistedPermissions()
            ?? AgentPermissionsManifest()
        guard !permissions.containsLocalExecAllowedCommand(commandIdentity) else {
            return
        }
        do {
            try AgentPermissionsManifestStore.save(
                permissions.appendingLocalExecAllowedCommand(commandIdentity)
            )
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

        let migrated = AgentPermissionsManifest(
            localExecAllowedCommands: (permissions?.localExecAllowedCommands ?? []) + legacyCommands
        )
        if migrated != permissions {
            try? AgentPermissionsManifestStore.save(migrated)
        }
        return migrated
    }
}
