//
//  TerminalSessionStoreError.swift
//  ZenCODE
//
//  Errors thrown when a saved session is validated before it is written or
//  after it is read.
//

import Foundation
import ToolCore

public enum TerminalSessionStoreError: LocalizedError, Equatable {
    case emptyName
    case emptySessionID
    case emptyWorkingDirectory
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Session name cannot be empty."
        case .emptySessionID:
            return "Session snapshot is missing a session id."
        case .emptyWorkingDirectory:
            return "Session snapshot is missing a working directory."
        case let .unsupportedVersion(version):
            return "Unsupported session file version: \(version)."
        }
    }
}
