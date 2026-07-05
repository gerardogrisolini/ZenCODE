//
//  MCPClientModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public nonisolated struct MCPRequest<Params: Encodable>: Encodable {
    public let jsonrpc: String
    public let id: MCPMessageID
    public let method: String
    public let params: Params
}

public nonisolated struct MCPNotification<Params: Encodable>: Encodable {
    public let jsonrpc: String
    public let method: String
    public let params: Params
}

public nonisolated struct MCPNotificationWithoutParams: Encodable {
    public let jsonrpc: String
    public let method: String
}

public nonisolated struct MCPInitializeParams: Encodable, Sendable {
    public let protocolVersion: String
    public let capabilities: MCPClientCapabilities
    public let clientInfo: MCPClientInfo
}

public nonisolated struct MCPClientCapabilities: Encodable, Sendable {}

public nonisolated struct MCPClientInfo: Encodable, Sendable {
    public let name: String
    public let version: String
}

public nonisolated struct MCPIncomingMessage: Decodable {
    public let id: MCPMessageID?
    public let result: JSONValue?
    public let error: MCPErrorResponse?
    public let method: String?
}

public nonisolated struct MCPErrorResponse: Decodable {
    public let code: Int
    public let message: String
}

public nonisolated struct MCPListToolsResult: Codable, Sendable {
    public let tools: [MCPRemoteTool]

    public func prettyPrintedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]

        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Unable to encode tools/list payload as UTF-8 text."
                )
            )
        }

        return json
    }
}

public nonisolated struct MCPRemoteTool: Codable, Hashable, Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    public let inputSchema: JSONValue?
    public let outputSchema: JSONValue?
}

public nonisolated enum MCPMessageID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }

        let value = try container.decode(String.self)
        self = .string(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}
