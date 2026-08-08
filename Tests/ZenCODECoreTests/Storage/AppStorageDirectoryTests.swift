//
//  AppStorageDirectoryTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct AppStorageDirectoryTests {
    @Test
    func coderSupportFilesUseTheEffectiveZenCodeDirectory() {
        AppStorageDirectory.configureSupportDirectoryURL(nil)
        AgentSettingsManifestStore.resetDefaultCacheForTesting()
        defer {
            AppStorageDirectory.configureSupportDirectoryURL(nil)
            AgentSettingsManifestStore.resetDefaultCacheForTesting()
        }

        let defaultSupportDirectory = UserHomeDirectory.current()
            .appendingPathComponent(".zencode", isDirectory: true)
            .standardizedFileURL
        let supportDirectory = AppStorageDirectory.appSupportDirectoryURL()

        #expect(AppStorageDirectory.defaultSupportDirectoryURL() == defaultSupportDirectory)
        #expect(ZenFileService.supportDirectoryURL() == supportDirectory)
        #expect(AgentsContextService().globalAgentsFileURL() == supportDirectory.appendingPathComponent("AGENTS.md"))
        #expect(SavedSessionsStore().sessionsFileURL() == supportDirectory.appendingPathComponent("sessions.json"))
        #expect(AgentSettingsManifestStore.settingsURL() == supportDirectory.appendingPathComponent("settings.json"))
        #expect(AgentProfileStore.agentsManifestURL() == supportDirectory.appendingPathComponent("agents.json"))
        #expect(PromptSkillCatalog.appCatalogSearchRoots() == [
            supportDirectory.appendingPathComponent("skills", isDirectory: true)
        ])
        #expect(SwiftFeatureRegistry.appFeatureRootURL() == supportDirectory.appendingPathComponent("features", isDirectory: true))
    }

    @Test
    func unscopedSupportDirectoryReadsNeverReachTheRealZenCodeDirectory() {
        // Central backstop for the per-test task-local override: a suite that
        // forgets to scope itself, or a code path that escapes the scope by
        // hopping onto a detached task, must still not write into the
        // developer's `~/.zencode`.
        AppStorageDirectory.configureSupportDirectoryURL(nil)
        AgentSettingsManifestStore.resetDefaultCacheForTesting()
        defer {
            AppStorageDirectory.configureSupportDirectoryURL(nil)
            AgentSettingsManifestStore.resetDefaultCacheForTesting()
        }

        #expect(AppStorageDirectory.isRunningUnderTestHarness)
        let sandbox = AppStorageDirectory.testHarnessSandboxURL()
        #expect(sandbox != nil)
        // Stable for the whole process, so every unscoped read agrees.
        #expect(sandbox == AppStorageDirectory.testHarnessSandboxURL())
        #expect(AppStorageDirectory.appSupportDirectoryURL() == sandbox)
        #expect(AppStorageDirectory.appSupportDirectoryURL() != AppStorageDirectory.defaultSupportDirectoryURL())
        // The definition of the default location is unchanged: only what
        // callers resolve to is redirected.
        #expect(
            AppStorageDirectory.defaultSupportDirectoryURL()
                == UserHomeDirectory.current()
                .appendingPathComponent(".zencode", isDirectory: true)
                .standardizedFileURL
        )
    }

    @Test
    func explicitOverridesStillWinOverTheTestHarnessSandbox() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-explicit-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        AppStorageDirectory.withSupportDirectoryURL(directory) {
            #expect(AppStorageDirectory.appSupportDirectoryURL() == directory.standardizedFileURL)
        }

        AppStorageDirectory.configureSupportDirectoryURL(directory)
        defer { AppStorageDirectory.configureSupportDirectoryURL(nil) }
        #expect(AppStorageDirectory.appSupportDirectoryURL() == directory.standardizedFileURL)
    }

    @Test
    func taskScopedSupportDirectoriesAndSettingsReadsRemainIsolated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-task-scoped-storage-\(UUID().uuidString)", isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        async let firstResult: (String, String?) = AppStorageDirectory.withSupportDirectoryURL(
            firstDirectory
        ) {
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [], responseLanguage: "it")
            )
            await Task.yield()
            return (
                AgentSettingsManifestStore.settingsURL().deletingLastPathComponent().path,
                try AgentSettingsManifestStore.loadRequired().responseLanguage
            )
        }
        async let secondResult: (String, String?) = AppStorageDirectory.withSupportDirectoryURL(
            secondDirectory
        ) {
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [], responseLanguage: "en")
            )
            await Task.yield()
            return (
                AgentSettingsManifestStore.settingsURL().deletingLastPathComponent().path,
                try AgentSettingsManifestStore.loadRequired().responseLanguage
            )
        }

        let (first, second) = try await (firstResult, secondResult)
        #expect(first.0 == firstDirectory.standardizedFileURL.path)
        #expect(first.1 == "it")
        #expect(second.0 == secondDirectory.standardizedFileURL.path)
        #expect(second.1 == "en")
    }

    @Test
    func settingsReadsObserveAnExternalAtomicReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-settings-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try AppStorageDirectory.withSupportDirectoryURL(directory) {
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [], responseLanguage: "it")
            )
            #expect(try AgentSettingsManifestStore.loadRequired().responseLanguage == "it")

            let replacement = AgentSettingsManifest(
                models: [],
                responseLanguage: "en"
            )
            try SensitiveFilePermissions.write(
                AgentSettingsManifestStore.encodedData(for: replacement),
                to: AgentSettingsManifestStore.settingsURL()
            )

            #expect(try AgentSettingsManifestStore.loadRequired().responseLanguage == "en")
        }
    }
}
