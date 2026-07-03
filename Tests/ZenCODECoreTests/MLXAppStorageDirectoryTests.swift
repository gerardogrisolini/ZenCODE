//
//  MLXAppStorageDirectoryTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct MLXAppStorageDirectoryTests {
    @Test
    func coderSupportFilesDefaultToHomeMlxCoderDirectory() {
        AppStorageDirectory.configureSupportDirectoryURL(nil)
        AgentSettingsManifestStore.resetDefaultCacheForTesting()
        defer {
            AppStorageDirectory.configureSupportDirectoryURL(nil)
            AgentSettingsManifestStore.resetDefaultCacheForTesting()
        }

        let supportDirectory = UserHomeDirectory.current()
            .appendingPathComponent(".zencode", isDirectory: true)
            .standardizedFileURL

        #expect(AppStorageDirectory.defaultSupportDirectoryURL() == supportDirectory)
        #expect(ZenFileService.supportDirectoryURL() == supportDirectory)
        #expect(AgentsContextService().globalAgentsFileURL() == supportDirectory.appendingPathComponent("AGENTS.md"))
        #expect(MemoryService().globalMemoryFileURL() == supportDirectory.appendingPathComponent("MEMORY.md"))
        #expect(AgentSettingsManifestStore.settingsURL() == supportDirectory.appendingPathComponent("settings.json"))
        #expect(AgentProfileStore.agentsManifestURL() == supportDirectory.appendingPathComponent("agents.json"))
        #expect(PromptSkillCatalog.appCatalogSearchRoots() == [
            supportDirectory.appendingPathComponent("skills", isDirectory: true)
        ])
        #expect(SwiftFeatureRegistry.appFeatureRootURL() == supportDirectory.appendingPathComponent("features", isDirectory: true))
    }
}
