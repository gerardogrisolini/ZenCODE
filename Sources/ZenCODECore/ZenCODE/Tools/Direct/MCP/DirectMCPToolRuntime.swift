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

/// Thrown when an install loses the per-server-family replacement race to a
/// newer install. Unlike shutdown, this leaves the newer server intact.
public struct MCPRuntimeInstallSupersededError: Error {}

public actor DirectMCPToolRuntime {
    public init() {}

    enum ServerFamily: Hashable {
        case figma
        case external(String)
    }

    struct Server {
        let family: ServerFamily
        let toolPrefix: String
        let backend: RemoteMCPToolExecutor
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

    var servers: [Server] = []
    /// The latest install request for each family. An owned install awaits its
    /// transport while the actor is reentrant; this generation prevents it
    /// from installing after a newer owned or borrowed request replaced it.
    private var installationGenerations: [ServerFamily: UInt64] = [:]
    /// Bumped by every `shutdown()`. Any install or discovery that was already
    /// suspended compares against the generation it captured before the await
    /// and disconnects its executor instead of appending a server to a runtime
    /// that was torn down.
    private var shutdownGeneration: UInt64 = 0

    struct ShutdownFence: Sendable, Equatable {
        fileprivate let generation: UInt64
    }

    struct InstallationFence: Sendable, Equatable {
        fileprivate let family: ServerFamily
        fileprivate let generation: UInt64
    }

    func shutdownFence() -> ShutdownFence {
        ShutdownFence(generation: shutdownGeneration)
    }

    func isActive(_ fence: ShutdownFence) -> Bool {
        shutdownGeneration == fence.generation
    }

    /// Begins a replacement transaction for one family. This intentionally
    /// invalidates a preceding transaction before it can resume from an await.
    func installationFence(for family: ServerFamily) -> InstallationFence {
        let generation = (installationGenerations[family] ?? 0) &+ 1
        installationGenerations[family] = generation
        return InstallationFence(family: family, generation: generation)
    }

    func isCurrent(_ fence: InstallationFence) -> Bool {
        installationGenerations[fence.family] == fence.generation
    }

    func isActive(_ shutdownFence: ShutdownFence, installationFence: InstallationFence) -> Bool {
        isActive(shutdownFence) && isCurrent(installationFence)
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
    func disconnectStaleExecutor(_ backend: RemoteMCPToolExecutor, ownsBackend: Bool) async {
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
        let shutdownFence = shutdownFence()
        let installFence = installationFence(for: family)
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
        let previousServers = servers.filter { $0.family == family }
        servers.removeAll { $0.family == family }
        for server in previousServers {
            await server.disconnectIfOwned()
        }
        guard isActive(shutdownFence, installationFence: installFence) else {
            return []
        }
        guard !descriptors.isEmpty else {
            return []
        }
        servers.append(
            Server(
                family: family,
                toolPrefix: toolPrefix,
                backend: executor,
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
        let family = ServerFamily.external(Self.externalServerID(for: name))
        let shutdownFence = shutdownFence()
        let installFence = installationFence(for: family)
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
        guard isActive(shutdownFence, installationFence: installFence) else {
            try throwIfInstallIsInactive(
                shutdownFence: shutdownFence,
                installationFence: installFence
            )
            return []
        }

        let toolPrefix = Self.externalToolPrefix(for: name)
        let executor = RemoteMCPToolExecutor(
            configuration: configuration,
            toolNamePrefix: toolPrefix,
            localTransportPolicy: .standard
        )
        do {
            let tools = ToolDescriptor.canonicalized(try await executor.loadTools())
            guard isActive(shutdownFence, installationFence: installFence) else {
                await disconnectStaleExecutor(executor, ownsBackend: true)
                try throwIfInstallIsInactive(
                    shutdownFence: shutdownFence,
                    installationFence: installFence
                )
                return []
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
            guard isActive(shutdownFence, installationFence: installFence) else {
                await disconnectStaleExecutor(executor, ownsBackend: true)
                try throwIfInstallIsInactive(
                    shutdownFence: shutdownFence,
                    installationFence: installFence
                )
                return []
            }
            servers.append(
                Server(
                    family: family,
                    toolPrefix: toolPrefix,
                    backend: executor,
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

    /// Converts a failed fence check into the reason visible to the caller.
    /// Kept after an await boundary rather than using `defer`: actor isolation
    /// is re-entered at every suspension point.
    func throwIfInstallIsInactive(
        shutdownFence: ShutdownFence,
        installationFence: InstallationFence
    ) throws {
        if !isActive(shutdownFence) {
            throw MCPRuntimeShutdownError()
        }
        if !isCurrent(installationFence) {
            throw MCPRuntimeInstallSupersededError()
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

    /// Discovery is driven by explicit feature installation; the runtime
    /// no longer discovers servers implicitly.
    func discoverIfNeeded(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil,
        force: Bool = false
    ) async {
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
