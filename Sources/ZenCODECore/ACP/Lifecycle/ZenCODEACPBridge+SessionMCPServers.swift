//
//  ZenCODEACPBridge+SessionMCPServers.swift
//  ZenCODE
//
//  The MCP servers an ACP client provides to a session, installed unless a
//  loaded feature of the same name already provides their tools.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// What the MCP servers an ACP client provides to a session contribute to its
/// tool grant: the tools of the servers that were installed, and the tool
/// names of the loaded features that replaced a server instead of it. Both
/// enter the session's grant in the same place
/// (``ZenCODEACPBridge/allowedToolNames(_:adding:replacingFeatureToolNames:)``).
struct ACPProvidedMCPServers {
    /// The tools of the servers that were installed.
    var descriptors: [DirectToolDescriptor] = []
    /// The tool names a session is granted when it selects each feature that
    /// replaced a server (`feature:<id>` in an agent profile): the tools and
    /// the tool-name prefixes of the feature.
    var replacingFeatureToolNames: Set<String> = []
}

extension ZenCODEACPBridge {
    /// The loaded features that replace servers of a request: the normalized
    /// server ids (`DirectMCPToolRuntime.externalServerID(for:)`) they take
    /// over, and the tool names a session selecting them is granted.
    private struct ReplacingFeatures {
        var serverIDs: Set<String> = []
        var toolNames: Set<String> = []
    }

    /// The loaded features of the injected feature runtime (installed and
    /// enabled) whose normalized id is that of one of the servers named
    /// `serverNames`, whatever the session's own tool grant selects. The tool
    /// names are the ones a profile selecting `feature:<id>` is granted
    /// (`TerminalToolSelectionCatalog`), computed on the statuses of that
    /// runtime. A loaded feature with no grantable name takes over nothing:
    /// its server would leave the session without those tools. Never starts a
    /// feature's tool discovery or the consent it can ask for.
    private func replacingFeatures(
        ofServersNamed serverNames: [String]
    ) async -> ReplacingFeatures {
        let serverIDs = Set(serverNames.map(DirectMCPToolRuntime.externalServerID(for:)))
        let featureRuntime = sessionRunner.swiftFeatureRuntime
        // `nil` restricts nothing, so every loaded feature is relevant to it.
        let candidateFeatureIDs = await featureRuntime.featureIDs(relevantTo: nil)
            .filter { serverIDs.contains(DirectMCPToolRuntime.externalServerID(for: $0)) }
            .sorted()
        guard !candidateFeatureIDs.isEmpty else {
            return ReplacingFeatures()
        }
        let items = TerminalToolSelectionCatalog.items(
            featureStatuses: await featureRuntime.featureStatuses(
                includeTools: true,
                includeDisabled: true,
                discoverRuntimeTools: false
            )
        )
        var replacing = ReplacingFeatures()
        for featureID in candidateFeatureIDs {
            let toolNames = TerminalToolSelectionCatalog.allowedToolNames(
                for: [TerminalToolSelectionCatalog.featurePackageKey(id: featureID)],
                items: items
            )
            guard !toolNames.isEmpty else {
                continue
            }
            replacing.serverIDs.insert(DirectMCPToolRuntime.externalServerID(for: featureID))
            replacing.toolNames.formUnion(toolNames)
        }
        return replacing
    }

    /// Installs the MCP servers `params` provide and returns their tools,
    /// with the tool names of the features that replace the ones it skipped.
    ///
    /// A server whose normalized id is that of a loaded feature is the same
    /// integration offered twice: Xcode passes its `xcode-tools` MCP bridge to
    /// every session, including one whose agent does not run the `xcode-tools`
    /// feature. Such a server is not installed, whatever the session's own
    /// tool grant selects: the session is granted the feature's tools instead
    /// (``ACPProvidedMCPServers/replacingFeatureToolNames``), so it opens one
    /// connection to the integration, and asks for its consent once, and the
    /// model is not given two copies of the same tools. A server with no
    /// loaded feature of its name is installed. The rule compares ids only.
    ///
    /// The installation is fenced by `operation` and `ownership` as before:
    /// a lifecycle operation that is no longer live installs nothing more and
    /// releases what it installed.
    func installACPProvidedMCPServers(
        from params: [String: Any],
        ownership: DirectMCPToolRuntime.MCPSessionOwnership? = nil,
        operation: UInt64? = nil
    ) async -> ACPProvidedMCPServers {
        let definitions = Self.mcpServerDefinitions(from: params)
        guard !definitions.isEmpty else {
            return ACPProvidedMCPServers()
        }
        let replacingFeatures = await replacingFeatures(ofServersNamed: definitions.map(\.name))

        var descriptors: [DirectToolDescriptor] = []
        for definition in definitions {
            // Re-check per iteration, not only after the whole loop: each
            // install suspends, so a shutdown landing inside one must stop the
            // remaining definitions from connecting new servers at all.
            if let operation, !isLifecycleOperationLive(operation) {
                // Servers already installed for this incarnation are orphaned
                // by the aborted creation: release them before bailing out.
                if let ownership {
                    await sessionRunner.releaseSessionMCPOwnership(
                        sessionID: ownership.sessionID,
                        epoch: ownership.epoch
                    )
                }
                return ACPProvidedMCPServers()
            }
            guard !replacingFeatures.serverIDs.contains(
                DirectMCPToolRuntime.externalServerID(for: definition.name)
            ) else {
                ZenLogger.info(
                    .viewModelRuntime,
                    "ACP MCP server '\(definition.name)' is not installed: the feature of the same name provides its tools."
                )
                continue
            }
            do {
                let installedDescriptors = try await sessionRunner.installACPProvidedMCPServer(
                    name: definition.name,
                    configuration: definition.configuration,
                    ownership: ownership
                )
                descriptors.append(contentsOf: installedDescriptors)
            } catch {
                ZenLogger.warning(
                    .viewModelRuntime,
                    "failed to install ACP MCP server '\(definition.name)': \(error.localizedDescription)"
                )
            }
        }
        return ACPProvidedMCPServers(
            descriptors: DirectToolExecutor.canonicalized(descriptors),
            replacingFeatureToolNames: replacingFeatures.toolNames
        )
    }

    /// Installs the MCP servers `params` provide and returns their tools: the
    /// source-compatible form of ``installACPProvidedMCPServers(from:ownership:operation:)``,
    /// which also returns the tool names of the features that replace the
    /// servers it skips. A caller that grants the session the returned tools
    /// itself must add those names as well, or use that form.
    ///
    /// `requestedAllowedToolNames` is ignored: whether a feature replaces a
    /// server no longer depends on the session's own tool grant. The parameter
    /// stays so that existing callers keep compiling.
    public func registerACPProvidedMCPServers(
        from params: [String: Any],
        requestedAllowedToolNames: Set<String>? = nil,
        ownership: DirectMCPToolRuntime.MCPSessionOwnership? = nil,
        operation: UInt64? = nil
    ) async -> [DirectToolDescriptor] {
        _ = requestedAllowedToolNames
        return await installACPProvidedMCPServers(
            from: params,
            ownership: ownership,
            operation: operation
        ).descriptors
    }
}
