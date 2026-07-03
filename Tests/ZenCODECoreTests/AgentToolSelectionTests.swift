//
//  AgentConfigurationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

extension AgentConfigurationTests {
    @Test
    func toolSelectionKeysKeepCoreAndFeaturePackagesDistinct() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "search-tools",
                    source: .bundled,
                    tools: ["search.glob", "search.grep"]
                ),
                featureStatus(
                    id: "git-tools",
                    source: .bundled,
                    tools: ["git.status"]
                )
            ]
        )

        let selectedKeys = try TerminalChat.parseToolSelection(
            "shell files text search git",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("text.wc"))
        #expect(!allowedToolNames.contains("feature.list"))
        #expect(allowedToolNames.contains("search.grep"))
        #expect(allowedToolNames.contains("git.status"))
    }

    @Test
    func defaultAgentProfilesEnableCoreAndFeaturePackageTools() {
        let profile = AgentProfile(
            id: "default",
            name: "Default",
            tools: AgentProfileStore.defaultToolNames
        )
        let allowedToolNames = profile.allowedToolNames()

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("search.grep"))
        #expect(allowedToolNames.contains("text.wc"))
        #expect(!allowedToolNames.contains("feature.list"))
    }

    @Test
    func xcodeToolReferencesSelectRuntimePackageBeforeDiscovery() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "xcode-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["xcode.", "Xcode"],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let xcodeKey = TerminalToolSelectionCatalog.featurePackageKey(id: "xcode-tools")

        let selectedKeys = TerminalChat.toolSelectionKeys(
            from: ["xcode", "xcode.", "xcode.BuildProject", "XcodeBuildProject"],
            items: items
        )
        let discoveryPrefixes = TerminalToolSelectionCatalog.externalDiscoveryPrefixes(
            for: selectedKeys,
            items: items
        )

        #expect(selectedKeys == Set([xcodeKey]))
        #expect(discoveryPrefixes.contains("xcode."))
    }

    @Test
    func agentAllowedToolNamesNormalizeDirectXcodeReferences() {
        let profile = AgentProfile(
            id: "xcode-agent",
            name: "Xcode Agent",
            tools: ["xcode", "xcode.BuildProject"]
        )

        let allowedToolNames = profile.allowedToolNames()

        #expect(DirectMCPToolRuntime.discoveryFamilies(allowedToolNames: allowedToolNames).contains("xcode"))
        #expect(DirectToolExecutor.isAllowed("xcode.BuildProject", allowedToolNames: allowedToolNames))
    }

    @Test
    func unavailableXcodeStaysSelectedButIsNotDiscoverable() {
        let requestedToolNames = Set([
            "local.exec",
            "xcode.",
            "xcode.BuildProject",
            "Xcode",
            "figma."
        ])

        let allowedToolNames = ExternalToolAvailability.resolvedAllowedToolNames(requestedToolNames)
        let discoverableToolNames = ExternalToolAvailability.discoverableToolPrefixes(
            requestedToolNames,
            xcodeIsRunning: false
        )

        #expect(allowedToolNames?.contains("local.exec") == true)
        #expect(allowedToolNames?.contains("figma.") == true)
        #expect(allowedToolNames?.contains("xcode.") == true)
        #expect(allowedToolNames?.contains("xcode.BuildProject") == true)
        #expect(allowedToolNames?.contains("Xcode") == true)
        #expect(discoverableToolNames.contains("xcode.") == false)
        #expect(discoverableToolNames.contains("xcode.BuildProject") == false)
        #expect(discoverableToolNames.contains("Xcode") == false)
    }

    @Test
    func toolSelectionChangeResetsSessionAndInformsModel() async throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-tool-selection",
            isDirectory: true
        )
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        let runner = AgentCoreSessionRunner()
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        let items = TerminalChat.toolSelectionItems(featureStatuses: [])
        terminal.selectedToolKeys = try TerminalChat.parseToolSelection(
            "shell",
            items: items
        )
        terminal.activeSessionHistory = [
            AgentRuntimeMessage(role: .user, content: "First request"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "I used shell.",
                toolCalls: [
                    AgentRuntimeToolCall(
                        id: "call_shell",
                        name: "local.exec",
                        argumentsJSON: #"{"cmd":"pwd"}"#
                    )
                ]
            ),
            AgentRuntimeMessage(
                role: .tool,
                content: workingDirectory.path,
                toolCallID: "call_shell",
                toolName: "local.exec"
            )
        ]

        try await terminal.createCurrentSession(discoverExternalTools: false)
        terminal.selectedToolKeys = []
        let allowedToolNames = await terminal.updateCurrentSessionToolOptions(
            discoverExternalTools: false
        )
        let snapshot = try #require(await runner.snapshotSession(id: terminal.sessionID))
        let notice = try #require(snapshot.history.last)

        #expect(allowedToolNames.isEmpty)
        #expect(snapshot.allowedToolNames == [])
        #expect(notice.role == .system)
        #expect(notice.content.contains("Tool selection changed during this session."))
        #expect(notice.content.contains("Current available tool names: none."))
        #expect(notice.content.contains("Removed tool names:"))
        #expect(notice.content.contains("local.exec"))
        #expect(notice.content.contains("historical context"))
    }

    @Test
    func xcodeWorkspaceRootMatchesNestedWorkingDirectoryButRejectsSiblings() {
        #expect(
            XcodeWorkspaceContext.workspaceRootPath(
                "/tmp/XcodeApp",
                matchesPreferredRootPath: "/tmp/XcodeApp/Modules/Feature"
            )
        )
        #expect(
            XcodeWorkspaceContext.workspaceRootPath(
                "/tmp/XcodeApp/XcodeApp.xcodeproj",
                matchesPreferredRootPath: "/tmp/XcodeApp"
            )
        )
        #expect(
            !XcodeWorkspaceContext.workspaceRootPath(
                "/tmp/OtherApp",
                matchesPreferredRootPath: "/tmp/XcodeApp"
            )
        )
    }

    @Test
    func xcodeDiscoveryRejectsDifferentWorkspace() async {
        let runtime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                Self.xcodeDiscovery(workspacePath: "/tmp/OtherApp/OtherApp.xcodeproj")
            }
        )

        let descriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/XcodeApp")
        )

        #expect(descriptors.isEmpty)
    }

    @Test
    func xcodeDiscoveryAcceptsWorkspaceContainingWorkingDirectory() async {
        let runtime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                Self.xcodeDiscovery(workspacePath: "/tmp/XcodeApp/XcodeApp.xcodeproj")
            }
        )

        let descriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/XcodeApp/Modules/Feature")
        )

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
    }

    @Test
    func xcodeDiscoveryKeepsGrantedSessionForMismatchedWorkspace() async {
        let discoveryProbe = XcodeDiscoveryProbe()
        let runtime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                await discoveryProbe.discovery(workspacePath: "/tmp/XcodeApp/XcodeApp.xcodeproj")
            }
        )

        let initialDescriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/XcodeApp")
        )
        let otherWorkspaceDescriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/OtherApp")
        )
        let restoredWorkspaceDescriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/XcodeApp")
        )

        #expect(initialDescriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(otherWorkspaceDescriptors.isEmpty)
        #expect(restoredWorkspaceDescriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(await discoveryProbe.count() == 1)
    }

    @Test
    func appSessionConfigurationKeepsClosedXcodeSelection() throws {
        let xcodeAgent = AgentProfile(
            id: "xcode-agent",
            name: "Xcode Agent",
            tools: ["shell", "xcode"]
        )

        let allowedToolNames = AgentCoreAppSessionFactory.resolvedAllowedToolNames(
            selectedToolKeys: nil,
            explicitAllowedToolNames: nil,
            selectedAgent: xcodeAgent
        )

        #expect(allowedToolNames?.contains("local.exec") == true)
        #expect(allowedToolNames?.contains("xcode.") == true)
    }

    @Test
    func groupedModelTitlesOmitRedundantProviderFallback() throws {
        let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let fallbackTitleModel = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: nil,
            modelID: "mlx-community/qwen3",
            providerID: providerID,
            providerName: "mlx-server",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .responses,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )
        let titledModel = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: "Qwen3 Local",
            modelID: "mlx-community/qwen3-local",
            providerID: providerID,
            providerName: "mlx-server",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .responses,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )

        let group = try #require(
            AgentModelCatalogPresentation.groupedByProvider([fallbackTitleModel, titledModel])
                .first { $0.title == "mlx-server" }
        )

        #expect(fallbackTitleModel.displayTitle == "mlx-server - mlx-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: fallbackTitleModel) == "mlx-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: fallbackTitleModel, in: group) == "mlx-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: titledModel, in: group) == "Qwen3 Local")
    }
}
