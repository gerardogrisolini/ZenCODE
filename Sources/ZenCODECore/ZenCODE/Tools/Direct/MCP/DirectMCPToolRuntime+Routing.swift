//
//  DirectMCPToolRuntime+Routing.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension DirectMCPToolRuntime {
    func serverAndToolName(for toolName: String) -> (Server, String)? {
        for server in servers {
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

enum DirectMCPToolRuntimeError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown MCP tool: \(name)"
        }
    }
}
