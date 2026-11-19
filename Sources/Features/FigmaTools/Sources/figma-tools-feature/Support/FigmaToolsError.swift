//
//  FigmaToolsError.swift
//  ZenCODE
//
//  User-visible failures of the Figma cloud tools. Messages never include the
//  access token value.
//

import Foundation

enum FigmaToolsError: LocalizedError, Equatable {
    /// Figma rejected the signed-in token (invalid, expired, revoked, or
    /// missing a scope); the session signs in again once.
    case authenticationFailed(String)
    case invalidCredentialStore(String)
    case loginTimedOut
    case loginFailed(String)
    case missingFileReference
    case missingNodeID(tool: String)
    case invalidReference(String)
    case invalidArgument(name: String, message: String)
    case nodeNotFound(nodeID: String, fileKey: String)
    case http(status: Int, message: String)
    case rateLimited(retryAfter: String?, limitType: String?)
    case invalidResponse(String)
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case let .authenticationFailed(message):
            return "Figma rejected the login: \(message)"
        case let .invalidCredentialStore(message):
            return "The stored Figma login is not usable (\(message)). Sign in again with figma.login."
        case .loginTimedOut:
            return "Figma login was not completed within 10 minutes. Run figma.login to try again."
        case let .loginFailed(message):
            return "Figma login failed: \(message)"
        case .missingFileReference:
            return "Pass a Figma link as url (for example from Copy link to selection) or a fileKey."
        case let .missingNodeID(tool):
            return "\(tool) needs a node: pass a Figma link that contains node-id (Copy link to selection) or a nodeId such as 1:2."
        case let .invalidReference(message):
            return "Invalid Figma reference: \(message)"
        case let .invalidArgument(name, message):
            return "Invalid argument \(name): \(message)"
        case let .nodeNotFound(nodeID, fileKey):
            return "Figma node \(nodeID) was not found in file \(fileKey), or the signed-in account cannot access it."
        case let .http(status, message):
            return "Figma API error \(status): \(message)"
        case let .rateLimited(retryAfter, limitType):
            var message = "Figma API rate limit reached"
            if let limitType { message += " (\(limitType))" }
            if let retryAfter { message += "; retry after \(retryAfter) seconds" }
            return message + "."
        case let .invalidResponse(message):
            return "Unexpected Figma API response: \(message)"
        case let .renderFailed(message):
            return "Figma render failed: \(message)"
        }
    }
}
