import Foundation

public nonisolated struct ToolDescriptor: Codable, Identifiable, Hashable, Sendable {
    /// Runtime-only identity for UI collections. It is deliberately excluded
    /// from `CodingKeys`; `name` and descriptor fields, not this UUID, define
    /// wire-level compatibility and canonical ordering.
    public var id = UUID()
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: String
    public let outputSchema: String?
    public let presentation: ToolPresentationDefinition?

    public enum CodingKeys: String, CodingKey {
        case name, title, description, inputSchema, outputSchema, presentation
    }

    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: String,
        outputSchema: String? = nil,
        presentation: ToolPresentationDefinition? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.presentation = presentation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decode(String.self, forKey: .description)
        self.inputSchema = try container.decode(String.self, forKey: .inputSchema)
        self.outputSchema = try container.decodeIfPresent(String.self, forKey: .outputSchema)

        self.presentation = try? container.decodeIfPresent(ToolPresentationDefinition.self, forKey: .presentation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
        try container.encodeIfPresent(presentation, forKey: .presentation)
    }

    public func prefixed(with prefix: String) -> ToolDescriptor {
        ToolDescriptor(
            name: "\(prefix)\(name)",
            title: title,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            presentation: presentation
        )
    }

    public static func canonicalized(_ tools: [ToolDescriptor]) -> [ToolDescriptor] {
        tools.sorted(by: canonicalSortOrder(lhs: rhs:))
    }

    private static func canonicalSortOrder(lhs: ToolDescriptor, rhs: ToolDescriptor) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }

        if lhs.title != rhs.title {
            return (lhs.title ?? "") < (rhs.title ?? "")
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
