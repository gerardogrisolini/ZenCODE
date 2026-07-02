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
        MLXAppStorageDirectory.configureSupportDirectoryURL(nil)
        AgentSettingsManifestStore.resetDefaultCacheForTesting()
        defer {
            MLXAppStorageDirectory.configureSupportDirectoryURL(nil)
            AgentSettingsManifestStore.resetDefaultCacheForTesting()
        }

        let supportDirectory = MLXUserHomeDirectory.current()
            .appendingPathComponent(".zencode", isDirectory: true)
            .standardizedFileURL

        #expect(MLXAppStorageDirectory.defaultSupportDirectoryURL() == supportDirectory)
        #expect(ZenCODESupportFileService.supportDirectoryURL() == supportDirectory)
        #expect(MLXAgentsContextService().globalAgentsFileURL() == supportDirectory.appendingPathComponent("AGENTS.md"))
        #expect(MLXMemoryService().globalMemoryFileURL() == supportDirectory.appendingPathComponent("MEMORY.md"))
        #expect(AgentSettingsManifestStore.settingsURL() == supportDirectory.appendingPathComponent("settings.json"))
        #expect(AgentProfileStore.agentsManifestURL() == supportDirectory.appendingPathComponent("agents.json"))
        #expect(MLXPromptSkillCatalog.appCatalogSearchRoots() == [
            supportDirectory.appendingPathComponent("skills", isDirectory: true)
        ])
        #expect(SwiftFeatureRegistry.appFeatureRootURL() == supportDirectory.appendingPathComponent("features", isDirectory: true))
    }
}
