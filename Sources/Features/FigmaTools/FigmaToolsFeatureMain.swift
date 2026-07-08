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
}
