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
        // `echo` (which remains prompt-worthy because redirects can write files).
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "pwd && echo ok") == "echo")
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
    func persistedAllowedCommandsMatchExecutablesRegardlessOfArguments() {
        let permissions = AgentPermissionsManifest(
            localExecAllowedCommands: [
                "swift test --filter OldFilter",
                "pwd && echo ok"
            ]
        )

        // `swift test --filter OldFilter` normalizes to the `swift` identity.
        // `pwd && echo ok` skips the harmless `pwd` and normalizes to `echo`.
        #expect(permissions.localExecAllowedCommands == ["swift", "echo"])
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "swift test --filter ZenCODECoreTests",
                permissions: permissions
            )
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "pwd && echo ok",
                permissions: permissions
            )
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "  pwd && echo no  ",
                permissions: permissions
            )
        )
        #expect(
            !LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "git status --short",
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
                " pwd && echo ok "
            ]
        )
        try AgentPermissionsManifestStore.save(manifest, to: url)
        let decoded = try AgentPermissionsManifestStore.loadRequired(from: url)

        // `pwd` is a harmless builtin and is skipped, so the entry normalizes
        // to its first authorizable executable `echo`.
        #expect(decoded.localExecAllowedCommands == ["swift", "echo"])
        #expect(decoded.containsLocalExecAllowedCommand("SWIFT"))
        #expect(decoded.containsLocalExecAllowedCommand("ECHO"))
    }
}
