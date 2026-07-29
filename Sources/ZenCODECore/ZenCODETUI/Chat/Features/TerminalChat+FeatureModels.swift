//
//  TerminalChat+FeatureModels.swift
//  ZenCODE
//

import Foundation

struct TerminalFeatureListPayload: Decodable {
    let features: [SwiftFeatureStatus]
}

enum FeatureWizardTemplate: Hashable, Sendable {
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

struct FeatureWizardCreationPlan: Equatable, Sendable {
    let buildsScaffold: Bool
    let enablesScaffold: Bool
    let selectsScaffold: Bool
    let runsImplementationPrompt: Bool
    let enablesAfterImplementation: Bool

    init(
        template: FeatureWizardTemplate,
        activateAfterSuccessfulBuild: Bool
    ) {
        switch template {
        case .basic:
            buildsScaffold = false
            enablesScaffold = false
            selectsScaffold = false
            runsImplementationPrompt = true
            enablesAfterImplementation = activateAfterSuccessfulBuild
        case .mcpBridge:
            buildsScaffold = true
            enablesScaffold = activateAfterSuccessfulBuild
            selectsScaffold = activateAfterSuccessfulBuild
            runsImplementationPrompt = false
            enablesAfterImplementation = false
        }
    }
}

enum FeatureWizardTransport: Hashable, Sendable {
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
