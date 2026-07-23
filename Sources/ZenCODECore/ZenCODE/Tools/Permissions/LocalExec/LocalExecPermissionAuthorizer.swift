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

    private struct DialogWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var alwaysAllowedKeys = Set<String>()
    private var didLoadPersistedAllowedCommands = false
    private var isDialogActive = false
    private var dialogWaiters: [DialogWaiter] = []
    private var cancelledDialogWaiterIDs = Set<UUID>()

    /// Injected single-key reader for consent prompts. When nil, the default
    /// terminal reader is used. The TUI sets this to route consent through its
    /// shared interactive reader (avoiding a second terminal input device),
    /// and tests set it for deterministic loop/EOF coverage.
    var consentReader: ConsentKeyReader?

    func setConsentReader(_ reader: ConsentKeyReader?) {
        consentReader = reader
    }

    /// Tool names this authorizer gates: shell commands plus the destructive
    /// direct tools. Everything else is pre-approved by tool selection.
    public static let gatedToolNames: Set<String> =
        DirectToolExecutor.destructiveGatedToolNames.union(["local.exec"])

    public init() {}

    public func authorize(_ request: AgentToolAuthorizationRequest) async -> Bool {
        guard Self.gatedToolNames.contains(request.toolName) else {
            return true
        }

        // Consent is presented on the terminal for every platform. SSH sessions
        // (including into a remote macOS host) expose a pseudo-tty, so the
        // prompt reaches the operator on all platforms.
        loadPersistedAllowedCommandsIfNeeded()
        let cacheKeys = permissionCacheKeys(for: request)
        if cacheKeys.allSatisfy(alwaysAllowedKeys.contains) {
            return true
        }

        // Actor isolation alone does not serialize this method across
        // `presentDialog`: the actor is re-entrant while terminal input is
        // awaited. Explicitly queue dialogs so concurrent tool calls can never
        // install multiple readers on the same TTY or fight over panel focus.
        guard await acquireDialogSlot() else {
            return false
        }
        defer { releaseDialogSlot() }
        guard !Task.isCancelled else {
            return false
        }

        // A request ahead of us may have selected Always while this request was
        // queued, so avoid presenting a now-redundant dialog.
        if cacheKeys.allSatisfy(alwaysAllowedKeys.contains) {
            return true
        }

        guard let decision = await presentDialog(for: request) else {
            return false
        }
        guard !Task.isCancelled else {
            return false
        }

        switch decision {
        case .allowOnce:
            return true
        case .allowAlways:
            alwaysAllowedKeys.formUnion(cacheKeys)
            // Only shell command identities are persisted across sessions;
            // destructive tool approvals live for the current process only.
            if request.toolName == "local.exec" {
                Self.persistAllowedCommand(request.command)
            }
            return true
        case .deny:
            return false
        }
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

    private func permissionCacheKeys(for request: AgentToolAuthorizationRequest) -> [String] {
        let identities: [String]
        if request.toolName == "local.exec" {
            let parsedIdentities = Self.localExecPermissionCacheIdentities(for: request.command)
            identities = parsedIdentities.isEmpty ? [request.command] : parsedIdentities
        } else {
            identities = [request.command]
        }
        return identities.map {
            Self.permissionCacheKey(toolName: request.toolName, identity: $0)
        }
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

    private static func persistAllowedCommandIdentities(_ commandIdentities: [String]) {
        let permissions = persistedPermissions()
            ?? AgentPermissionsManifest()
        let updatedPermissions = permissions.appendingLocalExecAllowedCommandIdentities(
            commandIdentities
        )
        guard updatedPermissions != permissions else {
            return
        }
        do {
            try AgentPermissionsManifestStore.save(updatedPermissions)
        } catch {
            return
        }
    }

    private func acquireDialogSlot() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard isDialogActive else {
            isDialogActive = true
            return true
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancelledDialogWaiterIDs.remove(waiterID) != nil {
                    continuation.resume(returning: false)
                } else {
                    dialogWaiters.append(
                        DialogWaiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelDialogWaiter(id: waiterID)
            }
        }

        guard acquired, !Task.isCancelled else {
            cancelledDialogWaiterIDs.remove(waiterID)
            if acquired {
                // Ownership may already have been handed to this waiter just as
                // it was cancelled; pass the slot on instead of stranding it.
                releaseDialogSlot()
            }
            return false
        }
        return true
    }

    private func releaseDialogSlot() {
        guard !dialogWaiters.isEmpty else {
            isDialogActive = false
            return
        }
        dialogWaiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelDialogWaiter(id: UUID) {
        if let index = dialogWaiters.firstIndex(where: { $0.id == id }) {
            dialogWaiters.remove(at: index).continuation.resume(returning: false)
        } else {
            // Cancellation can race ahead of continuation registration.
            cancelledDialogWaiterIDs.insert(id)
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
            try? AgentPermissionsManifestStore.save(migrated)
        }
        return migrated
    }
}
