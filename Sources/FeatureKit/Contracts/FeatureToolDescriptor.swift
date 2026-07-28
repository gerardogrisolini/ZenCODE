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
    public let presentation: ToolPresentationDefinition

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, outputSchema, presentation
    }

    public init(
        name: String,
        description: String,
        inputSchema: String,
        outputSchema: String? = nil,
        presentation: ToolPresentationDefinition = .automatic
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.presentation = presentation.validOrAutomatic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.inputSchema = try container.decode(String.self, forKey: .inputSchema)
        self.outputSchema = try container.decodeIfPresent(String.self, forKey: .outputSchema)

        let decodedPresentation: ToolPresentationDefinition?
        do {
            decodedPresentation = try container.decodeIfPresent(
                ToolPresentationDefinition.self,
                forKey: .presentation
            )
        } catch {
            decodedPresentation = nil
        }
        self.presentation = (decodedPresentation ?? .automatic).validOrAutomatic
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
        if !presentation.isAutomatic {
            try container.encode(presentation, forKey: .presentation)
        }
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
            outputSchema: toolDescriptor.outputSchema,
            presentation: toolDescriptor.presentation
        )
    }

    /// Feature descriptors do not expose a title, so this intentionally maps
    /// only the fields represented by the feature protocol.
    var toolDescriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            presentation: presentation
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
