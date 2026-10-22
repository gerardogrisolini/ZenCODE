//
//  FigmaToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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

    /// Opens one TCP connection to the Figma Desktop MCP port and reports
    /// whether it accepted. The probe always ends by cancelling the connection,
    /// whichever of readiness, failure, or the timeout comes first, so no
    /// connection or queue outlives the check.
    static func isRunning(timeout: TimeInterval = 0.5) async -> Bool {
        guard let endpointURL = configuration.endpointURL,
              let host = endpointURL.host,
              let portValue = endpointURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: portValue)) else {
            return false
        }
        let queue = DispatchQueue(label: "FigmaTools.FigmaDesktopMCPReachability")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        return await withCheckedContinuation { continuation in
            let state = Mutex(false)
            let finish: @Sendable (Bool) -> Void = { reachable in
                let shouldResume = state.withLock { finished in
                    guard !finished else { return false }
                    finished = true
                    return true
                }
                guard shouldResume else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                case .waiting:
                    // Loopback `waiting` means connection refused (Figma not
                    // listening); do not sit on the retry until the timeout.
                    finish(false)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
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
