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
    func commandPermissionIdentityUsesFirstWordOnly() {
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "swift test --filter ZenCODECoreTests") == "swift")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "git status --short --branch") == "git")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "python3 --version") == "python3")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "xcodebuild -list") == "xcodebuild")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "ls -la > out.txt") == "ls")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "pwd && rm -rf tmp") == "pwd")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "\n  echo ok > out.txt  \n") == "echo")
    }

    @Test
    func persistedCommandPermissionIdentityUsesFirstWordOnly() {
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "swift test --filter ZenCODECoreTests") == "swift")
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "pwd && echo ok") == "pwd")
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "\n  echo ok > out.txt  \n") == "echo")
    }

    @Test
    func persistedAllowedCommandsMatchExecutablesRegardlessOfArguments() {
        let permissions = AgentPermissionsManifest(
            localExecAllowedCommands: [
                "swift test --filter OldFilter",
                "pwd && echo ok"
            ]
        )

        #expect(permissions.localExecAllowedCommands == ["swift", "pwd"])
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

        #expect(decoded.localExecAllowedCommands == ["swift", "pwd"])
        #expect(decoded.containsLocalExecAllowedCommand("SWIFT"))
        #expect(decoded.containsLocalExecAllowedCommand("PWD"))
    }
}
