//
//  DirectMCPToolRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public actor DirectMCPToolRuntime {
    public struct XcodeDiscovery: Sendable {
        public let executor: XcodeToolExecutor
        public let tools: [ToolDescriptor]
        public let workspaceContexts: [XcodeWorkspaceContext]
        public let ownsExecutor: Bool

        public init(
            executor: XcodeToolExecutor,
            tools: [ToolDescriptor],
            workspaceContexts: [XcodeWorkspaceContext],
            ownsExecutor: Bool = true
        ) {
            self.executor = executor
            self.tools = tools
            self.workspaceContexts = workspaceContexts
            self.ownsExecutor = ownsExecutor
        }
    }

    public typealias XcodeDiscoveryProvider = @Sendable () async -> XcodeDiscovery?

    enum ServerFamily: Hashable {
        case xcode
        case figma
        case external(String)
    }

    enum Backend {
        case xcode(XcodeToolExecutor)
        case remote(RemoteMCPToolExecutor)

        func execute(_ request: ToolRequest) async throws -> ToolExecutionOutput {
            switch self {
            case let .xcode(executor):
                return try await executor.execute(request)
            case let .remote(executor):
                return try await executor.execute(request)
            }
        }

        func disconnect() async {
            switch self {
            case let .xcode(executor):
                await executor.disconnect()
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
        let workspaceRootPath: String?
        let ownsBackend: Bool
        let mcpConfiguration: MCPServerConfiguration?

        func disconnectIfOwned() async {
            guard ownsBackend else {
                return
            }
            await backend.disconnect()
        }
    }

    var didAttemptXcodeDiscovery = false
    var didAttemptFigmaDiscovery = false
    var servers: [Server] = []
    let autoDiscoverExternalConnectors: Bool
    let xcodeDiscoveryProvider: XcodeDiscoveryProvider

    public init(
        autoDiscoverExternalConnectors: Bool = false,
        xcodeDiscoveryProvider: @escaping XcodeDiscoveryProvider = DirectMCPToolRuntime.defaultXcodeDiscovery
    ) {
        self.autoDiscoverExternalConnectors = autoDiscoverExternalConnectors
        self.xcodeDiscoveryProvider = xcodeDiscoveryProvider
    }

    deinit {
        let servers = self.servers
        Task {
            for server in servers {
                await server.disconnectIfOwned()
            }
        }
    }

    public func shutdown() async {
        let currentServers = servers
        servers.removeAll()
        didAttemptXcodeDiscovery = false
        didAttemptFigmaDiscovery = false
        for server in currentServers {
            await server.disconnectIfOwned()
        }
    }

    public func installBorrowedXcodeExecutor(
        _ executor: XcodeToolExecutor,
        tools: [ToolDescriptor]
    ) async {
        _ = await installXcodeExecutor(
            executor,
            tools: tools,
            workspaceContexts: [],
            preferredWorkspaceRootURL: nil,
            ownsExecutor: false
        )
    }

    public func installXcodeExecutor(
        _ executor: XcodeToolExecutor,
        tools: [ToolDescriptor],
        workspaceContexts: [XcodeWorkspaceContext],
        preferredWorkspaceRootURL: URL?,
        ownsExecutor: Bool
    ) async -> [DirectToolDescriptor] {
        let descriptors = ToolDescriptor.canonicalized(tools)
            .map { tool in
                let name = tool.name.hasPrefix("xcode.")
                    ? tool.name
                    : "xcode.\(tool.name)"
                return DirectToolDescriptor(
                    name: name,
                    description: tool.description.hasPrefix("Xcode:")
                        ? tool.description
                        : "Xcode: \(tool.description)",
                    inputSchema: tool.inputSchema
                )
            }

        let previousXcodeServers = servers.filter { $0.family == .xcode }
        servers.removeAll { $0.family == .xcode }
        didAttemptXcodeDiscovery = true

        for server in previousXcodeServers {
            await server.disconnectIfOwned()
        }

        guard !descriptors.isEmpty else {
            return []
        }

        let matchedWorkspaceContext = workspaceContexts.isEmpty
            ? nil
            : matchedXcodeWorkspaceContext(
                in: workspaceContexts,
                preferredWorkspaceRootURL: preferredWorkspaceRootURL
            )
        guard workspaceContexts.isEmpty || matchedWorkspaceContext != nil else {
            return []
        }

        servers.append(
            Server(
                family: .xcode,
                toolPrefix: "xcode.",
                backend: .xcode(executor),
                descriptors: descriptors,
                workspaceRootPath: matchedWorkspaceContext?.normalizedWorkspaceRootPath,
                ownsBackend: ownsExecutor,
                mcpConfiguration: nil
            )
        )
        return descriptors
    }

    public func installExternalMCPServer(
        name: String,
        configuration: MCPServerConfiguration
    ) async throws -> [DirectToolDescriptor] {
        let externalServerID = Self.externalServerID(for: name)
        let family = ServerFamily.external(externalServerID)
        let shouldReuseExistingServer = externalServerID.contains("xcode")
            || configuration.usesMCPBridgeExecutable
        if shouldReuseExistingServer,
           let existingServer = servers.first(where: {
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

        let toolPrefix = Self.externalToolPrefix(for: name)
        let executor = RemoteMCPToolExecutor(
            configuration: configuration,
            toolNamePrefix: toolPrefix
        )
        do {
            let tools = ToolDescriptor.canonicalized(try await executor.loadTools())
            guard !tools.isEmpty else {
                await executor.disconnect()
                return []
            }

            let descriptors = tools.map { tool in
                DirectToolDescriptor(
                    name: tool.name,
                    description: "\(name): \(tool.description)",
                    inputSchema: tool.inputSchema
                )
            }
            servers.append(
                Server(
                    family: family,
                    toolPrefix: toolPrefix,
                    backend: .remote(executor),
                    descriptors: descriptors,
                    workspaceRootPath: nil,
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
        guard let allowedToolNames else {
            return servers
                .filter {
                    serverMatchesPreferredWorkspace(
                        $0,
                        preferredWorkspaceRootURL: preferredWorkspaceRootURL
                    )
                }
                .flatMap(\.descriptors)
        }

        guard !allowedToolNames.isEmpty else {
            return []
        }

        return servers
            .filter { server in
                serverIsRequested(
                    server,
                    allowedToolNames: allowedToolNames
                )
            }
            .filter {
                serverMatchesPreferredWorkspace(
                    $0,
                    preferredWorkspaceRootURL: preferredWorkspaceRootURL
                )
            }
            .flatMap(\.descriptors)
    }

    public func canExecute(
        toolName: String,
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> Bool {
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
        let normalizedRequest = normalizedToolRequest(request, for: server)

        let output = try await server.backend.execute(normalizedRequest)
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
            case .xcode:
                return "xcode"
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
            return [.xcode, .figma]
        }

        var families = Set<ServerFamily>()
        for toolName in allowedToolNames {
            if isXcodeToolName(toolName) {
                families.insert(.xcode)
            }
            if toolName.hasPrefix("figma.") {
                families.insert(.figma)
            }
        }
        return families
    }

    public static func isXcodeToolName(_ toolName: String) -> Bool {
        if toolName.hasPrefix("xcode.") || toolName.hasPrefix("Xcode") {
            return true
        }
        return unprefixedXcodeToolNames.contains(toolName)
    }

    static let unprefixedXcodeToolNames: Set<String> = [
        "BuildProject",
        "DocumentationSearch",
        "ExecuteSnippet",
        "GetBuildLog",
        "GetTestList",
        "RenderPreview",
        "RunAllTests",
        "RunSomeTests"
    ]

}
