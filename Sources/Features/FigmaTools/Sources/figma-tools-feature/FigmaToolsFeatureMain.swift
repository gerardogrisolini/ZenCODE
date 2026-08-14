//
//  FigmaToolsFeatureMain.swift
//  ZenCODE
//
//  Thin configuration for the Figma MCP tool feature.
//

import Foundation
import FeatureKit
import FeatureMCPBridgeKit
import ToolCore

@main
enum FigmaToolsFeature {
    static func main() async {
        await RemoteMCPFeatureRunner.run(configuration: FigmaFeatureConfiguration())
    }
}

private struct FigmaFeatureConfiguration: MCPFeatureConfiguration {
    let featureName = "Figma"
    let toolNamePrefix = "figma."
    let descriptionPrefix = "Figma: "
    let usageText = """
    Usage:
      figma-tools-feature --list-tools
      figma-tools-feature --invoke <tool-name> [--working-directory <path>]
    """

    func isAvailable(environment: [String: String]) async -> Bool {
        await MCPServerConfiguration.isFigmaDesktopServerRunning()
    }

    func makeExecutor(environment: [String: String]) async throws -> RemoteMCPToolExecutor {
        RemoteMCPToolExecutor(
            configuration: .figmaDesktopLocal(),
            toolNamePrefix: toolNamePrefix
        )
    }

    func listTools(
        environment: [String: String]
    ) async throws -> [FeatureToolDescriptor] {
        guard await isAvailable(environment: environment) else {
            return []
        }
        let executor = try await makeExecutor(environment: environment)
        let tools: [ToolDescriptor]
        do {
            tools = try await executor.loadTools()
        } catch {
            await executor.disconnect()
            throw error
        }
        await executor.disconnect()

        return ToolDescriptor.canonicalized(tools).map { tool in
            let descriptor = ToolDescriptor(
                name: tool.name,
                title: tool.title,
                description: tool.description,
                inputSchema: tool.inputSchema,
                outputSchema: tool.outputSchema,
                presentation: self.presentation(for: tool)
            )
            return FeatureToolDescriptor(
                toolDescriptor: descriptor,
                description: descriptor.description.hasPrefix(descriptionPrefix)
                    ? descriptor.description
                    : "\(descriptionPrefix)\(descriptor.description)",
                presentation: self.presentation(for: tool)
            )
        }
    }

    func presentation(for tool: ToolDescriptor) -> ToolPresentationDefinition {
        .standard(
            title: tool.title ?? "Figma",
            action: "Inspect",
            kind: .inspect,
            targetKeyPaths: [
                "nodeId", "node_id", "fileKey", "file_key",
                "url", "name", "query"
            ]
        )
    }
}
