//
//  FeatureResponses.swift
//  ZenCODE
//

import Foundation

/// Canonical response emitted by `--list-tools`.
public struct FeatureListToolsResponse: Codable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let tools: [FeatureToolDescriptor]

    public init(tools: [FeatureToolDescriptor]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
        let tools = try container.decode([FeatureToolDescriptor].self, forKey: .tools)
        if schemaVersion >= 2,
           tools.contains(where: { $0.presentation == nil }) {
            throw DecodingError.dataCorruptedError(
                forKey: .tools,
                in: container,
                debugDescription: "Feature list-tools schema v2 requires explicit presentation metadata for every tool."
            )
        }
        self.schemaVersion = schemaVersion
        self.tools = tools
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tools, forKey: .tools)
    }
}

/// Canonical error response emitted by a feature executable.
public struct FeatureErrorResponse: Codable, Sendable {
    public let ok: Bool
    public let error: String

    public init(error: String) {
        self.ok = false
        self.error = error
    }
}

/// Canonical successful invocation response for output that can be encoded
/// directly rather than passed through as already-encoded JSON.
public struct FeatureInvocationResponse<Output: Encodable & Sendable>: Encodable, Sendable {
    public let ok: Bool
    public let output: Output?
    public let error: String?

    public init(output: Output) {
        self.init(ok: true, output: output, error: nil)
    }

    public init(ok: Bool, output: Output?, error: String?) {
        self.ok = ok
        self.output = output
        self.error = error
    }
}
