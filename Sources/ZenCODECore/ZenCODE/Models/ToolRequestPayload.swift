//
//  ToolRequestPayload.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated struct ToolRequestPayload: Decodable, Sendable {
    public let tool: String
    public let arguments: [String: JSONValue]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        if let explicitTool = try container.decodeIfPresent(String.self, forKey: .tool),
           !explicitTool.isEmpty {
            tool = explicitTool
        } else if let fallbackTool = try container.decodeIfPresent(String.self, forKey: .name),
                  !fallbackTool.isEmpty {
            tool = fallbackTool
        } else {
            throw DecodingError.keyNotFound(
                DynamicCodingKey.tool,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing required tool name."
                )
            )
        }

        var normalizedArguments = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .arguments
        ) ?? [:]

        for key in container.allKeys where !DynamicCodingKey.reservedNames.contains(key.stringValue) {
            guard normalizedArguments[key.stringValue] == nil,
                  let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else {
                continue
            }

            normalizedArguments[key.stringValue] = value
        }

        arguments = normalizedArguments.isEmpty ? nil : normalizedArguments
    }
}

extension ToolRequestPayload {
    public struct DynamicCodingKey: CodingKey {
        public let stringValue: String
        public let intValue: Int?

        public init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        public init?(intValue: Int) {
            stringValue = "\(intValue)"
            self.intValue = intValue
        }

        public static let tool = DynamicCodingKey(stringValue: "tool")!
        public static let name = DynamicCodingKey(stringValue: "name")!
        public static let arguments = DynamicCodingKey(stringValue: "arguments")!
        public static let reservedNames: Set<String> = [
            DynamicCodingKey.tool.stringValue,
            DynamicCodingKey.name.stringValue,
            DynamicCodingKey.arguments.stringValue
        ]
    }
}
