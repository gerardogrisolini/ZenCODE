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

    public init() {}

    public func authorize(_ request: AgentToolAuthorizationRequest) async -> Bool {
        guard request.toolName == "local.exec" else {
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
            persistAllowedCommand(for: request)
            return true
        case .deny:
            return false
        }
        #endif
    }

    static func commandPermissionIdentity(for command: String) -> String? {
        // Use the shared parser: the identity is the first authorizable
        // executable of the first non-skip segment. Harmless built-ins/keywords
        // are skipped so that e.g. `pwd && rm -rf tmp` yields `rm` rather than
        // the inert `pwd`.
        for segment in LocalExecCommandParser.commandSegments(in: command) {
            switch LocalExecCommandParser.executableIdentity(for: segment) {
            case .skip:
                continue
            case .executable(let name):
                return name
            case .unresolved(let raw):
                return raw
            }
        }

        // All segments were skip (e.g. `true`, `cd /tmp`): no identity to
        // persist. Returning nil keeps the manifest and cache consistent with
        // `localExecAuthorizationCommands`, which produces no request for
        // all-skip commands.
        return nil
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
        [
            request.toolName,
            Self.persistedCommandPermissionIdentity(for: request.command) ?? request.command
        ].joined(separator: "\u{1f}")
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
            permissions.localExecAllowedCommands.map { "local.exec\u{1f}\($0)" }
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
