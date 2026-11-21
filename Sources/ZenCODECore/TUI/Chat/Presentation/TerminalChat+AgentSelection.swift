//
//  TerminalChat+AgentSelection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalChat {
    public func availableAgents() throws -> [AgentProfile] {
        try chatSession.availableAgents()
    }
}
