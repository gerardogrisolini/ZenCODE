//
//  ZenCODESetupMenuRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation

enum ZenCODESetupMenuRunner {
    static let option = "--setup"

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    static func movedSetupOption(in arguments: [String]) -> String? {
        let movedOptions = ["--setup-agents", "--reset"]
        return arguments.dropFirst().first { movedOptions.contains($0) }
    }
}

enum ZenCODESetupMenuError: LocalizedError {
    case setupActionMovedToSetup(String)

    var errorDescription: String? {
        switch self {
        case .setupActionMovedToSetup(let option):
            return "\(option) is now available from zen --setup."
        }
    }
}
