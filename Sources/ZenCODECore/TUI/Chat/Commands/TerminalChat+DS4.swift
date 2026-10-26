//
//  TerminalChat+DS4.swift
//  ZenCODE
//
//  `/ds4`: runtime controls of the in-process DS4 engine, the ones ds4-agent
//  offered as `/power`, `/steer` and `/hints`, plus a status report. The command
//  exists only while the current model has a DS4 runtime. It forwards to the
//  active backend (`AgentCoreSessionRunner.ds4Control`), never opens a model and
//  persists nothing: the values last as long as the backend session.
//

import Foundation

/// A parsed `/ds4` line.
enum TerminalDS4CommandAction: Sendable, Equatable {
    case control(AgentDS4ControlCommand)
    /// Missing or invalid arguments; `reason` explains what was wrong.
    case usage(reason: String?)

    static let usageMessage = """
    Usage:
      /ds4 status             Show model, backend, library, context, cache and runtime values
      /ds4 power <1-100>      Set the engine power for this session
      /ds4 steer <-100..100>  Set the FFN directional steering scale (needs a steering file)
      /ds4 hints on|off       Brief programming hints, from the next conversation boundary
    Values last for this session only; they are never saved.

    """

    /// Parses the text after `/ds4`.
    init(arguments: String) {
        let words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let subcommand = words.first?.lowercased() else {
            self = .usage(reason: nil)
            return
        }
        let operands = Array(words.dropFirst())
        switch subcommand {
        case "status":
            self = operands.isEmpty ? .control(.status) : .usage(reason: "/ds4 status takes no arguments")
        case "power":
            guard operands.count == 1, let percent = Self.integer(operands[0]) else {
                self = .usage(reason: "/ds4 power needs a whole number from 1 to 100")
                return
            }
            self = AgentDS4ControlCommand.powerRange.contains(percent)
                ? .control(.power(percent))
                : .usage(reason: "power must be between 1 and 100")
        case "steer":
            guard operands.count == 1, let scale = Self.number(operands[0]) else {
                self = .usage(reason: "/ds4 steer needs a number from -100 to 100")
                return
            }
            self = AgentDS4ControlCommand.steeringRange.contains(scale)
                ? .control(.steer(scale))
                : .usage(reason: "steering scale must be between -100 and 100")
        case "hints":
            switch operands.map({ $0.lowercased() }) {
            case ["on"]:
                self = .control(.hints(true))
            case ["off"]:
                self = .control(.hints(false))
            default:
                self = .usage(reason: "/ds4 hints needs on or off")
            }
        default:
            self = .usage(reason: "unknown /ds4 subcommand '\(words[0])'")
        }
    }

    /// Optional sign and digits only (ds4-agent `parse_power_percent`).
    private static func integer(_ text: String) -> Int? {
        let digits = text.hasPrefix("+") || text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(text)
    }

    /// A finite decimal number (ds4-agent `parse_steering_level`: no `nan`,
    /// no trailing garbage).
    private static func number(_ text: String) -> Double? {
        let allowed = Set("0123456789+-.eE")
        guard !text.isEmpty, text.allSatisfy({ allowed.contains($0) }),
              let value = Double(text), value.isFinite else {
            return nil
        }
        return value
    }
}

extension TerminalChat {
    /// Whether the model of the current session has a DS4 runtime; `/ds4` is
    /// available (and suggested) only then.
    func currentModelUsesDS4Runtime() -> Bool {
        guard let modelID = currentEffectiveModelID(),
              let model = availableModelManifests().first(where: { $0.matches(modelID) }) else {
            return false
        }
        return model.ds4Runtime != nil || model.provider?.ds4Runtime != nil
    }

    /// `/ds4 status|power|steer|hints`.
    func handleDS4Command(_ command: String) async {
        guard currentModelUsesDS4Runtime() else {
            await writeFailureMessage(Self.unknownCommandMessage(for: command))
            return
        }
        let arguments = Self.slashCommandArguments(from: command, commandPrefix: "/ds4")
        switch TerminalDS4CommandAction(arguments: arguments) {
        case let .usage(reason):
            if let reason {
                await writeFailureMessage("ZenCODE: \(reason).\n")
            }
            await writeSystemMessage(TerminalDS4CommandAction.usageMessage)
        case let .control(control):
            do {
                let result = try await sessionRunner.ds4Control(control, sessionID: sessionID)
                await writeSystemMessage(result.message + "\n")
            } catch {
                await writeFailureMessage("ZenCODE: /ds4: \(error.localizedDescription).\n")
            }
        }
    }
}
