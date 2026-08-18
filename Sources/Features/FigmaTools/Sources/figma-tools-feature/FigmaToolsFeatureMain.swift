//
//  FigmaToolsFeatureMain.swift
//  ZenCODE
//
//  Thin configuration for the Figma MCP tool feature.
//

import Foundation
import FeatureKit
import FeatureMCPBridgeKit
import Network
import Synchronization
import ToolCore

private enum FigmaDesktopMCP {
    static let configuration = MCPServerConfiguration(
        executablePath: "",
        arguments: [],
        environment: [:],
        endpointURL: URL(string: "http://127.0.0.1:3845/mcp"),
        httpHeaders: [:],
        httpAuthentication: .none,
        preferredProtocolVersion: "2025-03-26"
    )

    static func isRunning(timeout: TimeInterval = 0.5) async -> Bool {
        guard let endpointURL = configuration.endpointURL,
              let host = endpointURL.host,
              let portValue = endpointURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let state = Mutex(false)
            let finish: @Sendable (Bool) -> Void = { reachable in
                let shouldResume = state.withLock { finished in
                    guard !finished else { return false }
                    finished = true
                    return true
                }
                if shouldResume { continuation.resume(returning: reachable) }
            }
            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    finish(true)
                    connection.cancel()
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            let queue = DispatchQueue(label: "FigmaTools.FigmaDesktopMCPReachability")
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
                connection.cancel()
            }
            connection.start(queue: queue)
        }
    }
}

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
        await FigmaDesktopMCP.isRunning()
    }

    func makeExecutor(environment: [String: String]) async throws -> RemoteMCPToolExecutor {
        RemoteMCPToolExecutor(
            configuration: FigmaDesktopMCP.configuration,
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
