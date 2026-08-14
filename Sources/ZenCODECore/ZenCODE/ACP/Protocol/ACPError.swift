//
//  ACPError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct ACPError: LocalizedError {
    public let code: Int
    public let message: String

    public var errorDescription: String? {
        message
    }

    public static func invalidParams(_ message: String) -> ACPError {
        ACPError(code: -32602, message: message)
    }

    public static func internalError(_ message: String) -> ACPError {
        ACPError(code: -32603, message: message)
    }
}

