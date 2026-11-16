//
//  ZenCODEACPBridge+AvailableCommands.swift
//  ZenCODE
//
//  The slash commands an ACP session advertises (available_commands_update)
//  and their publication when they change.
//

import Foundation
import ToolCore

extension ZenCODEACPBridge {
    func availableCommandsUpdate(for session: SessionState) -> JSONValue {
        var commands: [JSONValue] = [.object([
            "name": .string("goal"),
            "description": .string("Work until the goal is complete or genuinely blocked"),
            "input": .object(["hint": .string("Goal to achieve")])
        ])]
        if acpSubAgentsAreAvailable(in: session) {
            for (name, description) in [("review", "Review with delegated agents"), ("plan", "Create or manage a plan")] {
                commands.append(.object([
                    "name": .string(name), "description": .string(description),
                    "input": .object(["hint": .string("Instructions or subcommand")])
                ]))
            }
        }
        commands.append(.object([
            "name": .string("tasks"),
            "description": .string("Show the session task graph, and retry, cancel, or clear its tasks"),
            "input": .object(["hint": .string("status, show <id>, retry <id>, cancel <id>, or clear")])
        ]))
        if Self.isTelegramCommandVisible() {
            commands.append(.object([
                "name": .string("telegram"),
                "description": .string("Telegram status, or turn it on/off for this session"),
                "input": .object(["hint": .string("on or off")])
            ]))
        }
        return .object(["sessionUpdate": .string("available_commands_update"), "availableCommands": .array(commands)])
    }

    func publishAvailableCommands(sessionID: String, epoch: UInt64) async {
        guard let session = liveSession(id: sessionID, epoch: epoch) else { return }
        let update = availableCommandsUpdate(for: session)
        guard session.presentedCommands != update else { return }
        sessions[sessionID]?.presentedCommands = update
        await writer.sendSessionUpdate(sessionID: sessionID, update: update)
    }
}
