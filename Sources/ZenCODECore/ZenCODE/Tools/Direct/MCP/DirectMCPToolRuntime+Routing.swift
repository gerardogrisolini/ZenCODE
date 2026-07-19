//
//  DirectMCPToolRuntime+Routing.swift
//  ZenCODE
//

import Foundation
#if canImport(XcodeToolsFeature)
import XcodeToolsFeature
#endif

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
        if toolName.hasPrefix(server.toolPrefix) {
            let rawToolName = String(toolName.dropFirst(server.toolPrefix.count))
            if server.descriptors.contains(where: { $0.name == toolName }) {
                return rawToolName
            }
            if serverIsXcodeLike(server),
               let canonicalToolName = XcodeToolIntegration.canonicalToolName(for: toolName),
               server.descriptors.contains(where: { $0.name == "\(server.toolPrefix)\(canonicalToolName)" }) {
                return canonicalToolName
            }
            return nil
        }

        guard serverIsXcodeLike(server),
              let canonicalToolName = XcodeToolIntegration.canonicalToolName(for: toolName),
              server.descriptors.contains(where: { $0.name == "\(server.toolPrefix)\(canonicalToolName)" }) else {
            return nil
        }
        return canonicalToolName
    }

    func normalizedToolRequest(_ request: ToolRequest, for server: Server) -> ToolRequest {
        guard serverIsXcodeLike(server) else {
            return request
        }
        return XcodeToolIntegration.normalizedRequest(request) ?? request
    }

    func serverIsXcodeLike(_ server: Server) -> Bool {
        switch server.family {
        case .xcode:
            return true
        case .external, .figma:
            return false
        }
    }

    public static func canonicalXcodeToolName(for toolName: String) -> String? {
        XcodeToolIntegration.canonicalToolName(for: toolName)
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
