//
//  TerminalChat+FeatureModels.swift
//  ZenCODE
//

import Foundation

struct TerminalFeatureListPayload: Decodable {
    let features: [SwiftFeatureStatus]
}

enum FeatureWizardTemplate: Hashable {
    case mcpBridge
    case basic

    func defaultDescription(displayName: String) -> String {
        switch self {
        case .mcpBridge:
            return "MCP bridge feature for \(displayName)."
        case .basic:
            return "Swift feature generated for ZenCODE."
        }
    }
}

enum FeatureWizardTransport: Hashable {
    case http
    case stdio
}

public enum TerminalFeatureCommandError: LocalizedError {
    case unknownFeature(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownFeature(value):
            return "Unknown feature '\(value)'. Use /feature list to see available feature ids."
        }
    }
}
