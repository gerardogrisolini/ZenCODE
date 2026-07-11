//
//  FeatureToolDescriptor.swift
//  ZenCODE
//

import Foundation
import ToolCore

public struct FeatureToolDescriptor: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: String
    public let outputSchema: String?

    public init(
        name: String,
        description: String,
        inputSchema: String,
        outputSchema: String? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

public extension FeatureToolDescriptor {
    /// Bridges the feature wire descriptor to ToolCore's canonical descriptor
    /// without changing the feature protocol's encoded shape.
    init(toolDescriptor: ToolDescriptor, description: String? = nil) {
        self.init(
            name: toolDescriptor.name,
            description: description ?? toolDescriptor.description,
            inputSchema: toolDescriptor.inputSchema,
            outputSchema: toolDescriptor.outputSchema
        )
    }

    /// Feature descriptors do not expose a title, so this intentionally maps
    /// only the fields represented by the feature protocol.
    var toolDescriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )
    }

    /// Sorts descriptors deterministically without deduplicating them or
    /// rewriting schema bytes. Duplicate registrations can be meaningful to a
    /// feature host, so collision resolution remains the host's responsibility.
    static func canonicalized(_ descriptors: [FeatureToolDescriptor]) -> [FeatureToolDescriptor] {
        descriptors.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            if lhs.description != rhs.description {
                return lhs.description < rhs.description
            }
            if lhs.inputSchema != rhs.inputSchema {
                return lhs.inputSchema < rhs.inputSchema
            }
            return (lhs.outputSchema ?? "") < (rhs.outputSchema ?? "")
        }
    }
}
