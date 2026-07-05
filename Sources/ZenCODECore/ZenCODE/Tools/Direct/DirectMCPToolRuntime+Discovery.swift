//
//  DirectMCPToolRuntime+Discovery.swift
//  ZenCODE
//

import Foundation

extension DirectMCPToolRuntime {
    func discoverFamilyIfNeeded(
        _ family: ServerFamily,
        preferredWorkspaceRootURL: URL?,
        force: Bool
    ) async {
        guard force || autoDiscoverExternalConnectors else {
            return
        }

        switch family {
        case .xcode:
            if let existingServer = servers.first(where: { $0.family == .xcode }) {
                if !serverMatchesPreferredWorkspace(
                    existingServer,
                    preferredWorkspaceRootURL: preferredWorkspaceRootURL
                ) {
                    // Keep the process-scoped Xcode authorization alive; descriptor filtering
                    // hides this server from workspaces it does not belong to.
                    return
                }
                return
            }
            let previousXcodeServers = servers.filter { $0.family == .xcode }
            guard force || !didAttemptXcodeDiscovery || !previousXcodeServers.isEmpty else {
                return
            }
            servers.removeAll { $0.family == .xcode }
            didAttemptXcodeDiscovery = true
            for server in previousXcodeServers {
                await server.disconnectIfOwned()
            }
            if let xcodeServer = await discoverXcodeServer(
                preferredWorkspaceRootURL: preferredWorkspaceRootURL
            ) {
                servers.append(xcodeServer)
            }
        case .figma:
            guard force || !didAttemptFigmaDiscovery else {
                return
            }
            guard !servers.contains(where: { $0.family == .figma }) else {
                return
            }
            didAttemptFigmaDiscovery = true
            if let figmaServer = await discoverFigmaServer() {
                servers.append(figmaServer)
            }
        case .external:
            return
        }
    }

    func discoverXcodeServer(
        preferredWorkspaceRootURL: URL?
    ) async -> Server? {
        guard let discovery = await xcodeDiscoveryProvider() else {
            return nil
        }

        let tools = ToolDescriptor.canonicalized(discovery.tools)
        guard !tools.isEmpty else {
            if discovery.ownsExecutor {
                await discovery.executor.disconnect()
            }
            return nil
        }

        guard let matchedWorkspaceContext = matchedXcodeWorkspaceContext(
            in: discovery.workspaceContexts,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        ) else {
            if discovery.ownsExecutor {
                await discovery.executor.disconnect()
            }
            return nil
        }

        return Server(
            family: .xcode,
            toolPrefix: "xcode.",
            backend: .xcode(discovery.executor),
            descriptors: tools.map { tool in
                DirectToolDescriptor(
                    name: "xcode.\(tool.name)",
                    description: "Xcode: \(tool.description)",
                    inputSchema: tool.inputSchema
                )
            },
            workspaceRootPath: matchedWorkspaceContext.normalizedWorkspaceRootPath,
            ownsBackend: discovery.ownsExecutor,
            mcpConfiguration: nil
        )
    }

    func discoverFigmaServer() async -> Server? {
        guard await MCPServerConfiguration.isFigmaDesktopServerRunning() else {
            return nil
        }

        let executor = RemoteMCPToolExecutor(
            configuration: .figmaDesktopLocal(),
            toolNamePrefix: "figma."
        )
        do {
            let tools = ToolDescriptor.canonicalized(
                try await executor.loadTools()
            )
            guard !tools.isEmpty else {
                await executor.disconnect()
                return nil
            }

            return Server(
                family: .figma,
                toolPrefix: "figma.",
                backend: .remote(executor),
                descriptors: tools.map { tool in
                    DirectToolDescriptor(
                        name: tool.name,
                        description: "Figma: \(tool.description)",
                        inputSchema: tool.inputSchema
                    )
                },
                workspaceRootPath: nil,
                ownsBackend: true,
                mcpConfiguration: .figmaDesktopLocal()
            )
        } catch {
            await executor.disconnect()
            return nil
        }
    }

    public static func defaultXcodeDiscovery() async -> XcodeDiscovery? {
        guard MCPServerConfiguration.isXcodeRunning(),
              let configuration = MCPServerConfiguration.xcodeFromEnvironment() else {
            return nil
        }

        let executor = XcodeToolExecutor(configuration: configuration)
        do {
            let tools = try await executor.loadTools()
            let workspaceContexts = try await executor.loadWorkspaceContexts()
            return XcodeDiscovery(
                executor: executor,
                tools: tools,
                workspaceContexts: workspaceContexts
            )
        } catch {
            ZenLogger.info(
                .xcodeToolExecutor,
                "Xcode MCP discovery failed after consent resolution: \(error.localizedDescription)"
            )
            await executor.disconnect()
            return nil
        }
    }

    public static func externalToolPrefix(for serverName: String) -> String {
        let base = externalServerID(for: serverName)
        return "\(base)."
    }

    static func externalServerID(for serverName: String) -> String {
        let scalars = serverName
            .lowercased()
            .unicodeScalars
            .map { scalar -> String in
                CharacterSet.alphanumerics.contains(scalar)
                    ? String(scalar)
                    : "-"
            }
        let normalized = scalars.joined()
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.nilIfBlank ?? "mcp"
    }

    func matchedXcodeWorkspaceContext(
        in contexts: [XcodeWorkspaceContext],
        preferredWorkspaceRootURL: URL?
    ) -> XcodeWorkspaceContext? {
        guard let preferredWorkspaceRootURL else {
            return contexts.first ?? XcodeWorkspaceContext(
                workspacePath: nil,
                defaultTabIdentifier: nil
            )
        }

        let preferredRootPath = preferredWorkspaceRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return contexts.first { context in
            XcodeWorkspaceContext.workspaceRootPath(
                context.normalizedWorkspaceRootPath,
                matchesPreferredRootPath: preferredRootPath
            )
        }
    }

    func serverMatchesPreferredWorkspace(
        _ server: Server,
        preferredWorkspaceRootURL: URL?
    ) -> Bool {
        guard server.family == .xcode else {
            return true
        }
        guard let preferredWorkspaceRootURL,
              let workspaceRootPath = server.workspaceRootPath else {
            return true
        }
        let preferredRootPath = preferredWorkspaceRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return XcodeWorkspaceContext.workspaceRootPath(
            workspaceRootPath,
            matchesPreferredRootPath: preferredRootPath
        )
    }

    func serverIsRequested(
        _ server: Server,
        allowedToolNames: Set<String>?
    ) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        guard !allowedToolNames.isEmpty else {
            return false
        }
        if Self.discoveryServerFamilies(allowedToolNames: allowedToolNames).contains(server.family) {
            return true
        }
        return server.descriptors.contains { descriptor in
            Self.toolName(
                descriptor.name,
                isAllowedBy: allowedToolNames
            )
        }
    }

    static func toolName(
        _ toolName: String,
        isAllowedBy allowedToolNames: Set<String>
    ) -> Bool {
        if allowedToolNames.contains(toolName) {
            return true
        }
        return allowedToolNames.contains { allowedToolName in
            allowedToolName.hasSuffix(".") && toolName.hasPrefix(allowedToolName)
        }
    }

}
