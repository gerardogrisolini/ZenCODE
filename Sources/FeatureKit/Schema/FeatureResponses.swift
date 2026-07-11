//
//  FeatureResponses.swift
//  ZenCODE
//

import Foundation

/// Canonical response emitted by `--list-tools`.
public struct FeatureListToolsResponse: Codable, Sendable {
    public let tools: [FeatureToolDescriptor]

    public init(tools: [FeatureToolDescriptor]) {
        self.tools = tools
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
