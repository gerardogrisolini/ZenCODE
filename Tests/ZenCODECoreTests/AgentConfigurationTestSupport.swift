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
    func featureStatus(
        id: String,
        displayName: String? = nil,
        source: SwiftFeatureBundleSource,
        tools: [String],
        toolNamePrefixes: [String] = [],
        discoversToolsAtRuntime: Bool = false,
        enabled: Bool = true,
        available: Bool = true
    ) -> SwiftFeatureStatus {
        SwiftFeatureStatus(
            id: id,
            displayName: displayName,
            description: nil,
            source: source,
            enabled: enabled,
            available: available,
            executablePath: "/tmp/\(id)",
            manifestPath: nil,
            tools: tools,
            toolNamePrefixes: toolNamePrefixes,
            toolNameAliases: [],
            discoversToolsAtRuntime: discoversToolsAtRuntime,
            build: nil,
            generated: nil,
            issue: nil
        )
    }

    func thinkingSelectionManifest(
        selectedThinkingSelection: AgentThinkingSelection
    ) -> AgentSettingsManifest {
        let provider = AgentRemoteProvider(
            name: "mlx-server",
            baseURL: "http://127.0.0.1",
            modelID: "mlx-community/qwen3"
        )
        let model = AgentSettingsModelManifest(
            kind: .remoteAPI,
            modelID: "mlx-community/qwen3",
            provider: provider,
            thinkingOptions: [.off, .low, .medium, .high],
            defaultThinkingSelection: .medium
        )
        return AgentSettingsManifest(
            models: [model],
            selectedModelID: model.id,
            selectedThinkingSelection: selectedThinkingSelection
        )
    }

    static func xcodeDiscovery(workspacePath: String) -> DirectMCPToolRuntime.XcodeDiscovery {
        DirectMCPToolRuntime.XcodeDiscovery(
            executor: XcodeToolExecutor(
                configuration: MCPServerConfiguration(
                    executablePath: "/usr/bin/false",
                    arguments: [],
                    environment: [:]
                )
            ),
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project.",
                    inputSchema: "{}"
                )
            ],
            workspaceContexts: [
                XcodeWorkspaceContext(
                    workspacePath: workspacePath,
                    defaultTabIdentifier: nil
                )
            ],
            ownsExecutor: false
        )
    }
}
