//
//  AgentCoreSessionRunner+MCP.swift
//  ZenCODE
//

import Foundation

extension AgentCoreSessionRunner {
    public func mcpToolDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await mcpRuntime.discoverDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
    }

    public func knownMCPToolDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await mcpRuntime.knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
    }

    public func installBorrowedXcodeExecutor(
        _ executor: XcodeToolExecutor?,
        tools: [ToolDescriptor]
    ) async {
        guard let executor,
              !tools.isEmpty else {
            return
        }

        await mcpRuntime.installBorrowedXcodeExecutor(
            executor,
            tools: tools
        )
    }

    public func installACPProvidedMCPServer(
        name: String,
        configuration: MCPServerConfiguration
    ) async throws -> [DirectToolDescriptor] {
        try await mcpRuntime.installExternalMCPServer(
            name: name,
            configuration: configuration
        )
    }

}
