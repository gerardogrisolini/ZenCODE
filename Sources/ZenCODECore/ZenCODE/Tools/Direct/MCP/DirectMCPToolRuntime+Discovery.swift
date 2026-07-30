//
//  DirectMCPToolRuntime+Discovery.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension DirectMCPToolRuntime {
    func discoverFamilyIfNeeded(
        _ family: ServerFamily,
        preferredWorkspaceRootURL: URL?,
        force: Bool
    ) async {
        _ = preferredWorkspaceRootURL
        guard force || autoDiscoverExternalConnectors else {
            return
        }
        guard discoveringFamilies.insert(family).inserted else {
            return
        }
        defer {
            discoveringFamilies.remove(family)
        }

        // Connector-specific discovery belongs to optional feature processes.
        // Direct MCP servers are installed explicitly through
        // `installExternalMCPServer` and require no vendor-specific branch here.
        switch family {
        case .figma, .external:
            return
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
            Self.toolName(descriptor.name, isAllowedBy: allowedToolNames)
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
