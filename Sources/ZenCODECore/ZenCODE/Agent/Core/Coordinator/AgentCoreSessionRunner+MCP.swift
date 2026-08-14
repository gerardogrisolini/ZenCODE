//
//  AgentCoreSessionRunner+MCP.swift
//  ZenCODE
//

import Foundation

extension AgentCoreSessionRunner {
    public func knownMCPToolDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await mcpRuntime.knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
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
