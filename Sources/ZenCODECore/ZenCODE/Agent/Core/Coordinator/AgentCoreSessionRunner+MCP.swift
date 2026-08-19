//
//  AgentCoreSessionRunner+MCP.swift
//  ZenCODE
//

import Foundation

extension AgentCoreSessionRunner {
    public func knownMCPToolDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil,
        sessionID: String? = nil
    ) async -> [DirectToolDescriptor] {
        await mcpRuntime.knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            sessionID: sessionID
        )
    }

    public func installACPProvidedMCPServer(
        name: String,
        configuration: MCPServerConfiguration,
        ownership: DirectMCPToolRuntime.MCPSessionOwnership? = nil
    ) async throws -> [DirectToolDescriptor] {
        try await mcpRuntime.installExternalMCPServer(
            name: name,
            configuration: configuration,
            ownership: ownership
        )
    }

    /// Releases the MCP servers registered by one ACP session incarnation.
    /// Called by `session/close`, by the lifecycle rollback paths and by
    /// `shutdown`; installations without session ownership are untouched.
    public func releaseSessionMCPOwnership(
        sessionID: String,
        epoch: UInt64
    ) async {
        await mcpRuntime.releaseSessionOwnership(sessionID: sessionID, epoch: epoch)
    }

}
