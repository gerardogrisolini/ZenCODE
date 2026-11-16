//
//  ZenCODEACPBridge+SessionMCPServers.swift
//  ZenCODE
//
//  The MCP servers an ACP client provides to a session, installed unless a
//  feature of the session's own tool grant already runs them.
//

import Foundation
import ToolCore

extension ZenCODEACPBridge {
    /// The server ids (`DirectMCPToolRuntime.externalServerID(for:)`) of the
    /// features a session with the tool grant `requestedAllowedToolNames`
    /// runs. `nil` names none: a session without a grant of its own that
    /// installs an MCP server is granted the tools of its servers only (see
    /// `allowedToolNames(_:adding:)`), so no feature runs beside them.
    private func sessionFeatureServerIDs(
        requestedAllowedToolNames: Set<String>?
    ) async -> Set<String> {
        guard let requestedAllowedToolNames else {
            return []
        }
        let featureIDs = await sessionRunner.swiftFeatureRuntime.featureIDs(
            relevantTo: requestedAllowedToolNames
        )
        return Set(featureIDs.map(DirectMCPToolRuntime.externalServerID(for:)))
    }

    /// Installs the MCP servers `params` provide and returns their tools.
    ///
    /// A server named like a feature the session's own tool grant
    /// (`requestedAllowedToolNames`) already selects is the same integration
    /// offered twice: Xcode passes its `xcode-tools` MCP bridge to every
    /// session, including one whose agent runs the `xcode-tools` feature.
    /// Such a server is not installed, so the session opens one connection to
    /// the integration, and asks for its consent once, instead of twice, and
    /// the model is not given two copies of the same tools. Without a grant
    /// (`nil`) every server is installed.
    public func registerACPProvidedMCPServers(
        from params: [String: Any],
        requestedAllowedToolNames: Set<String>? = nil,
        ownership: DirectMCPToolRuntime.MCPSessionOwnership? = nil,
        operation: UInt64? = nil
    ) async -> [DirectToolDescriptor] {
        let definitions = Self.mcpServerDefinitions(from: params)
        guard !definitions.isEmpty else {
            return []
        }
        let featureServerIDs = await sessionFeatureServerIDs(
            requestedAllowedToolNames: requestedAllowedToolNames
        )

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
                return []
            }
            guard !featureServerIDs.contains(
                DirectMCPToolRuntime.externalServerID(for: definition.name)
            ) else {
                ZenLogger.info(
                    .viewModelRuntime,
                    "ACP MCP server '\(definition.name)' is not installed: the session's feature of the same name provides its tools."
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
        return DirectToolExecutor.canonicalized(descriptors)
    }
}
