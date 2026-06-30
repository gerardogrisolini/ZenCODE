//
//  ToolRequest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public nonisolated struct ToolRequest: Hashable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]

    public init(
        name: String,
        arguments: [String: JSONValue]
    ) {
        self.name = name
        self.arguments = arguments
    }
}
