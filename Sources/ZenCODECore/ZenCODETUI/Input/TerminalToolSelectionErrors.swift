//
//  TerminalToolSelectionErrors.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

public enum TerminalToolSelectionError: LocalizedError {
    case unknownToken(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownToken(token):
            return "Unknown tool or package '\(token)'."
        }
    }
}

public enum TerminalSkillSelectionError: LocalizedError {
    case unknownToken(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownToken(token):
            return "Unknown skill '\(token)'."
        }
    }
}
