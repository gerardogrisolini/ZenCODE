//
//  LocalExecPermissionAuthorizerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 05/06/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct LocalExecPermissionAuthorizerTests {
    @Test
    func commandPermissionIdentityExtractsExecutable() {
        // Plain executables.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "swift test --filter ZenCODECoreTests") == "swift")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "git status --short --branch") == "git")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "python3 --version") == "python3")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "xcodebuild -list") == "xcodebuild")
        // Redirections are skipped, leaving the real executable.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "ls -la > out.txt") == "ls")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "2>&1 swift build") == "swift")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: ">out.txt echo hi") == "echo")
        // Harmless built-ins are skipped so the real command surfaces.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "pwd && rm -rf tmp") == "rm")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "true && rm -rf tmp") == "rm")
        // Environment assignments and wrappers are unwrapped.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "FOO=bar swift build") == "swift")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "env CI=1 swift test") == "swift")
        // Grouping delimiters are stripped.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "(cd /tmp && make)") == "make")
        // Leading/trailing whitespace and redirections are handled.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "\n  echo ok > out.txt  \n") == "echo")
    }

    @Test
    func persistedCommandPermissionIdentityExtractsExecutable() {
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "swift test --filter ZenCODECoreTests") == "swift")
        // `pwd` is a harmless builtin, so the first authorizable executable is
        // `git`. Decorative `echo` is filtered.
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "pwd && git status") == "git")
        // `echo` with redirection is NOT decorative and remains prompt-worthy.
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "\n  echo ok > out.txt  \n") == "echo")
    }

    @Test
    func allSkipCommandYieldsNilIdentity() {
        // M5: a command consisting entirely of harmless built-ins yields no
        // identity, consistent with `localExecAuthorizationCommands` returning [].
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "true") == nil)
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "false") == nil)
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "cd /tmp") == nil)
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "true") == nil)
    }

    @Test
    func persistedPermissionMatchesRegardlessOfCase() {
        // F10: the persisted manifest matches case-insensitively; verify the
        // identity extraction and manifest membership agree across cases.
        let permissions = AgentPermissionsManifest(
            localExecAllowedCommands: ["Swift"]
        )
        #expect(permissions.containsLocalExecAllowedCommand("swift"))
        #expect(permissions.containsLocalExecAllowedCommand("SWIFT"))
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "swift build",
                permissions: permissions
            )
        )
    }

    @Test
    func persistedAllowedCommandsMatchExecutablesRegardlessOfArguments() {
        let permissions = AgentPermissionsManifest(
            localExecAllowedCommands: [
                "swift test --filter OldFilter",
                "pwd && git status"
            ]
        )

        // `swift test --filter OldFilter` normalizes to the `swift` identity.
        // `pwd && git status` skips the harmless `pwd` and normalizes to `git`.
        #expect(permissions.localExecAllowedCommands == ["swift", "git"])
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "swift test --filter ZenCODECoreTests",
                permissions: permissions
            )
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "pwd && git status",
                permissions: permissions
            )
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "  pwd && git log  ",
                permissions: permissions
            )
        )
        #expect(
            !LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "rm -rf /tmp",
                permissions: permissions
            )
        )
    }

    @Test
    func terminalWorkspaceConsentAcceptsOnlyAffirmativeAnswers() {
        #expect(TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess(""))
        #expect(TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("y"))
        #expect(TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("YES"))
        #expect(TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("  yes  \r"))
        #expect(!TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("n"))
        #expect(!TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("no"))
        #expect(!TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("maybe"))
    }

    @Test
    func settingsManifestDecodesButDoesNotEncodeLegacyLocalExecPermissions() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            localExecAllowedCommands: [
                "swift"
            ]
        )

        let data = try JSONEncoder().encode(manifest)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("localExecAllowedCommands"))

        let legacyData = Data(
            #"""
            {
              "version": 8,
              "models": [],
              "localExecAllowedCommands": ["swift"]
            }
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: legacyData)
        #expect(decoded.localExecAllowedCommands == ["swift"])
    }

    @Test
    func permissionsManifestRoundTripsLocalExecPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("permissions.json")

        let manifest = AgentPermissionsManifest(
            localExecAllowedCommands: [
                "swift test",
                "swift build",
                " pwd && git status "
            ]
        )
        try AgentPermissionsManifestStore.save(manifest, to: url)
        let decoded = try AgentPermissionsManifestStore.loadRequired(from: url)

        // `pwd` is a harmless builtin and is skipped, so the entry normalizes
        // to its first authorizable executable `git`.
        #expect(decoded.localExecAllowedCommands == ["swift", "git"])
        #expect(decoded.containsLocalExecAllowedCommand("SWIFT"))
        #expect(decoded.containsLocalExecAllowedCommand("GIT"))
    }
}
