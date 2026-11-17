//
//  MCPClientError+PermissionDenied.swift
//  ZenCODE
//
//  The generic, cross-platform classification of MCP permission failures, so
//  every MCP connector and the host follow the same result contract.
//

import Foundation

extension MCPClientError {
    /// Whether the call was refused for lack of permission: an
    /// ``authorizationRequired(service:message:)`` error, or a server exit or
    /// server error whose message reads like a refusal
    /// (``messageIndicatesPermissionDenied(_:)``).
    public var indicatesPermissionDenied: Bool {
        switch self {
        case .authorizationRequired:
            return true
        case let .serverExited(_, message),
             let .serverError(_, message):
            return Self.messageIndicatesPermissionDenied(message)
        default:
            return false
        }
    }

    /// Whether `message` reads like a refused permission, without regard to
    /// case: "permission denied", "consent denied", "not authorized" (or
    /// "not authorised"), "not allowed", "not permitted", "rejected", or
    /// "declined".
    public static func messageIndicatesPermissionDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("permission denied")
            || lowered.contains("consent denied")
            || lowered.contains("not authorized")
            || lowered.contains("not authorised")
            || lowered.contains("not allowed")
            || lowered.contains("not permitted")
            || lowered.contains("rejected")
            || lowered.contains("declined")
    }
}
