//
//  LocalExecPermissionPolicy.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// The `local.exec` permission policy shared by every consent channel: the
/// executable identities a command is approved for, their persistence in the
/// permissions manifest, the in-memory cache keys, and the sanitizing of the
/// untrusted request fields shown to the operator.
///
/// It is channel-neutral. The terminal adapter (`LocalExecPermissionAuthorizer`
/// in `ZenCODECore`) and the Telegram broker both apply it, and
/// ``ChatToolConsentAuthorizer`` relies on it for every host.
package enum LocalExecPermissionPolicy {
    /// Tool names gated by consent: shell commands plus the destructive
    /// direct tools. Everything else is pre-approved by tool selection.
    static let gatedToolNames: Set<String> = ChatToolConsentAuthorizer.gatedToolNames

    /// The executable identities of `command` that a local-exec permission
    /// covers, in persisted form: every authorizable executable, in order.
    /// The shared parser's structured candidates filter harmless built-ins and
    /// keywords, comments, and decorative echo/printf, so that e.g.
    /// `pwd && rm -rf tmp` yields `rm` rather than the inert `pwd`.
    package static func persistedCommandPermissionIdentities(for command: String) -> [String] {
        LocalExecCommandParser.authorizationCandidates(in: command).map(\.identity)
    }

    package static func isCommandPersistentlyAllowed(
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

    package static func localExecPermissionCacheIdentities(for command: String) -> [String] {
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
    package static func permissionCacheKey(toolName: String, identity: String) -> String {
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

    // MARK: - Consent text

    package static func nonInteractiveConsentMessage(for request: AgentToolAuthorizationRequest) -> String {
        let hint = Self.alwaysChoiceHint(forToolName: request.toolName)
        return """
        \nPermission required but no interactive terminal is available (this \
        happens in CI, pipes, or background sessions).
        The command was blocked by design (fail-closed) and was not run.

        Command:
        \(request.command)

        To pre-approve it, run in an interactive session and choose \
        [A]lways. \(hint)
        """
    }

    /// Replaces the user's home-directory prefix with `~` so paths stay short.
    /// `zen --ui` prints its workspace with it too, over an injected home.
    package static func abbreviatedHomePath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let home = homeDirectory
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    /// Explains the scope of the "Always" choice so the consent dialog makes
    /// the authorization duration unambiguous:
    /// - `local.exec`: every executable identity in the request is remembered
    ///   across sessions (persisted to the permissions manifest), so future
    ///   commands ask only when they introduce an unapproved identity.
    /// - Destructive direct tools (delete, push, restore, …): "Always" grants
    ///   the tool for the current session/process only; it is never persisted.
    static func alwaysChoiceHint(forToolName toolName: String) -> String {
        if toolName == "local.exec" {
            "Always: remember every executable identity in this request across sessions."
        } else {
            "Always: allow this tool for this session only."
        }
    }

    /// Strips terminal control characters (ESC, CSI/OSC introducers, carriage
    /// return, bell, …) from untrusted request fields so a crafted command or
    /// title cannot clear, overwrite, or spoof the consent prompt. Newlines and
    /// tabs are preserved; other control bytes collapse to a space.
    package static func sanitizedForTerminal(_ text: String) -> String {
        String(text.map(Self.sanitizedTerminalCharacter))
    }

    /// The per-character rule of ``sanitizedForTerminal(_:)``: newlines and
    /// tabs are kept, a character whose first scalar is a C0 control or in
    /// 0x7F–0x9F becomes a space, any other character is kept.
    static func sanitizedTerminalCharacter(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first else {
            return " "
        }
        if character == "\n" || character == "\t" {
            return character
        }
        let value = scalar.value
        if value < 0x20 || (value > 0x7E && value < 0xA0) {
            return " "
        }
        return character
    }
}
