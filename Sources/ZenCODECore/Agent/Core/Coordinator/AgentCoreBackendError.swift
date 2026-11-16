//
//  AgentCoreBackendError.swift
//  ZenCODE
//
//  Errors reported by the agent core backend when the selected remote
//  provider or its API key is no longer configured.
//

import Foundation
import ToolCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AgentCoreBackendError: LocalizedError {
    case missingRemoteProvider
    case missingRemoteAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .missingRemoteProvider:
            return "The selected remote provider is no longer configured in ZenCODE."
        case let .missingRemoteAPIKey(providerName):
            return "No API key is stored for \(providerName). Run zen --setup to configure that provider."
        }
    }
}
