//
//  DirectMCPToolRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import FeatureMCPBridgeKit
import Foundation
import ToolCore

/// Thrown when an MCP server install completes after the runtime was shut
/// down. The caller treats it like any other install failure, so the ordinary
/// wire behaviour (the server is simply absent) is unchanged.
public struct MCPRuntimeShutdownError: Error {}

public actor DirectMCPToolRuntime {
    enum ServerFamily: Hashable {
        case figma
        case external(String)
    }

    enum Backend {
        case remote(RemoteMCPToolExecutor)

        func execute(_ request: ToolRequest) async throws -> ToolExecutionOutput {
            switch self {
            case let .remote(executor):
                return try await executor.execute(request)
            }
        }

        func disconnect() async {
            switch self {
            case let .remote(executor):
                await executor.disconnect()
            }
        }
    }

    struct Server {
        let family: ServerFamily
        let toolPrefix: String
        let backend: Backend
        let descriptors: [DirectToolDescriptor]
        let ownsBackend: Bool
        let mcpConfiguration: MCPServerConfiguration?

        func disconnectIfOwned() async {
            guard ownsBackend else {
                return
            }
            await backend.disconnect()
        }
    }

    /// Per-family single-flight latch. Actor reentrancy permits another caller
    /// to enter while discovery awaits I/O, so booleans alone cannot prevent
    /// duplicate executor/process creation.
    var discoveringFamilies: Set<ServerFamily> = []
    var servers: [Server] = []
    /// Bumped by every `shutdown()`. Any install or discovery that was already
    /// suspended compares against the generation it captured before the await
    /// and disconnects its executor instead of appending a server to a runtime
    /// that was torn down.
    private var shutdownGeneration: UInt64 = 0

    struct ShutdownFence: Sendable, Equatable {
        fileprivate let generation: UInt64
    }

    func shutdownFence() -> ShutdownFence {
        ShutdownFence(generation: shutdownGeneration)
    }

    func isActive(_ fence: ShutdownFence) -> Bool {
        shutdownGeneration == fence.generation
    }

    let autoDiscoverExternalConnectors: Bool

    public init(autoDiscoverExternalConnectors: Bool = false) {
        self.autoDiscoverExternalConnectors = autoDiscoverExternalConnectors
    }

    deinit {
        let servers = self.servers
        Task(name: "Direct MCP runtime deinit disconnect") {
            for server in servers {
                await server.disconnectIfOwned()
            }
        }
    }

    public func shutdown() async {
        let currentServers = servers
        servers.removeAll()
        shutdownGeneration &+= 1
        for server in currentServers {
            await server.disconnectIfOwned()
        }
    }

    /// Tears down an executor that finished connecting for a runtime
    /// generation that no longer exists.
    func disconnectStaleExecutor(_ backend: Backend, ownsBackend: Bool) async {
        guard ownsBackend else {
            return
        }
        await backend.disconnect()
    }

    /// Registers a caller-owned MCP executor without transferring its lifecycle
    /// to the runtime. This is the generic embedding path for hosts that already
    /// own an MCP connection.
    public func installBorrowedExternalExecutor(
        name: String,
        executor: RemoteMCPToolExecutor,
        tools: [ToolDescriptor]
    ) async -> [DirectToolDescriptor] {
        let family = ServerFamily.external(Self.externalServerID(for: name))
        let toolPrefix = Self.externalToolPrefix(for: name)
        let descriptors = ToolDescriptor.canonicalized(tools).map { tool in
            DirectToolDescriptor(
                name: tool.name.hasPrefix(toolPrefix) ? tool.name : "\(toolPrefix)\(tool.name)",
                description: "\(name): \(tool.description)",
                inputSchema: tool.inputSchema,
                title: tool.title,
                outputSchema: tool.outputSchema,
                presentation: tool.presentation
            )
        }
        servers.removeAll { $0.family == family }
        guard !descriptors.isEmpty else {
            return []
        }
        servers.append(
            Server(
                family: family,
                toolPrefix: toolPrefix,
                backend: .remote(executor),
                descriptors: descriptors,
                ownsBackend: false,
                mcpConfiguration: nil
            )
        )
        return descriptors
    }

    public func installExternalMCPServer(
        name: String,
        configuration: MCPServerConfiguration
    ) async throws -> [DirectToolDescriptor] {
        let fence = shutdownFence()
        let family = ServerFamily.external(Self.externalServerID(for: name))
        if let existingServer = servers.first(where: {
            $0.family == family
                && $0.mcpConfiguration == configuration
                && !$0.descriptors.isEmpty
        }) {
            return existingServer.descriptors
        }

        let previousServers = servers.filter { $0.family == family }
        servers.removeAll { $0.family == family }
        for server in previousServers {
            await server.disconnectIfOwned()
        }
        guard isActive(fence) else {
            throw MCPRuntimeShutdownError()
        }

        let toolPrefix = Self.externalToolPrefix(for: name)
        let executor = RemoteMCPToolExecutor(
            configuration: configuration,
            toolNamePrefix: toolPrefix,
            localTransportPolicy: .standard
        )
        do {
            let tools = ToolDescriptor.canonicalized(try await executor.loadTools())
            guard isActive(fence) else {
                await disconnectStaleExecutor(.remote(executor), ownsBackend: true)
                throw MCPRuntimeShutdownError()
            }
            guard !tools.isEmpty else {
                await executor.disconnect()
                return []
            }

            let descriptors = tools.map { tool in
                DirectToolDescriptor(
                    name: tool.name,
                    description: "\(name): \(tool.description)",
                    inputSchema: tool.inputSchema,
                    title: tool.title,
                    outputSchema: tool.outputSchema,
                    presentation: tool.presentation
                )
            }
            servers.append(
                Server(
                    family: family,
                    toolPrefix: toolPrefix,
                    backend: .remote(executor),
                    descriptors: descriptors,
                    ownsBackend: true,
                    mcpConfiguration: configuration
                )
            )
            return descriptors
        } catch {
            await executor.disconnect()
            throw error
        }
    }

    public func descriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await discoverIfNeeded(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        return knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
    }

    public func discoverDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await discoverIfNeeded(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            force: true
        )
        return knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
    }

    public func knownDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) -> [DirectToolDescriptor] {
        _ = preferredWorkspaceRootURL
        guard let allowedToolNames else {
            return servers.flatMap(\.descriptors)
        }
        guard !allowedToolNames.isEmpty else {
            return []
        }
        return servers
            .filter { serverIsRequested($0, allowedToolNames: allowedToolNames) }
            .flatMap(\.descriptors)
    }

    public func canExecute(
        toolName: String,
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> Bool {
        if serverAndToolName(for: toolName) != nil {
            return true
        }
        let discoveryToolNames = allowedToolNames ?? [toolName]
        await discoverIfNeeded(
            allowedToolNames: discoveryToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        return serverAndToolName(for: toolName) != nil
    }

    public func execute(toolCall: DirectAgentToolCall) async throws -> String {
        guard let (server, rawToolName) = serverAndToolName(for: toolCall.name) else {
            throw DirectMCPToolRuntimeError.unknownTool(toolCall.name)
        }
        let request = ToolRequest(
            name: rawToolName,
            arguments: Self.jsonValueArguments(from: toolCall.argumentsObject)
        )
        let output = try await server.backend.execute(request)
        return output.text
    }

    func discoverIfNeeded(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil,
        force: Bool = false
    ) async {
        for family in Self.discoveryServerFamilies(allowedToolNames: allowedToolNames) {
            await discoverFamilyIfNeeded(
                family,
                preferredWorkspaceRootURL: preferredWorkspaceRootURL,
                force: force
            )
        }
    }

    public static func discoveryFamilies(
        allowedToolNames: Set<String>?
    ) -> Set<String> {
        let families = discoveryServerFamilies(allowedToolNames: allowedToolNames)
        return Set(families.map {
            switch $0 {
            case .figma:
                return "figma"
            case let .external(name):
                return name
            }
        })
    }

    static func discoveryServerFamilies(
        allowedToolNames: Set<String>?
    ) -> Set<ServerFamily> {
        guard let allowedToolNames else {
            return [.figma]
        }
        return allowedToolNames.contains { $0.hasPrefix("figma.") }
            ? [.figma]
            : []
    }
}
