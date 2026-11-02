//
//  TerminalChat+Utilities.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension TerminalChat {
    nonisolated static func slashCommandArguments(
        from command: String,
        commandPrefix: String
    ) -> String {
        ChatCommandRegistry.arguments(from: command, commandPrefix: commandPrefix)
    }
}
