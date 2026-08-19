//
//  DirectMCPToolRuntime+Routing.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension DirectMCPToolRuntime {
    func serverAndToolName(
        for toolName: String,
        sessionID: String? = nil
    ) -> (Server, String)? {
        for server in servers.visible(to: sessionID) {
            guard let rawToolName = rawToolName(toolName, for: server) else {
                continue
            }
            return (server, rawToolName)
        }
        return nil
    }

    func rawToolName(_ toolName: String, for server: Server) -> String? {
        guard toolName.hasPrefix(server.toolPrefix),
              server.descriptors.contains(where: { $0.name == toolName }) else {
            return nil
        }
        return String(toolName.dropFirst(server.toolPrefix.count))
    }

    static func jsonValueArguments(from object: [String: Any]) -> [String: JSONValue] {
        guard case let .object(arguments) = JSONValue(jsonObject: object) else {
            return [:]
        }
        return arguments
    }
}

extension [DirectMCPToolRuntime.Server] {
    /// Session-scoped view of the server list: session-owned servers are
    /// visible only to their owning session id, unowned (shared) servers are
    /// visible to everyone. A `nil` session id keeps only shared servers.
    func visible(to sessionID: String?) -> [DirectMCPToolRuntime.Server] {
        filter { $0.isVisible(to: sessionID) }
    }
}

enum DirectMCPToolRuntimeError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown MCP tool: \(name)"
        }
    }
}
