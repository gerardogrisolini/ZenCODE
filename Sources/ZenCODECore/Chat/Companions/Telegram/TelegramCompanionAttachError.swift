//
//  TelegramCompanionAttachError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Why ``TelegramSessionCompanion/attach()`` could not link the session to
/// Telegram.
///
/// The primary channel presents ``failureText`` on its failure channel. That
/// is the text the terminal wrote for the same failure, byte for byte, with
/// its `ZenCODE: ` prefix and its trailing newline, so a terminal that
/// presents it is unchanged.
enum TelegramCompanionAttachError: Error, Sendable, Equatable {
    /// The settings hold no linked chat: Telegram was never paired.
    case notPaired
    /// The settings do not resolve to exactly one owner route this session
    /// can use: an unsupported routing schema, a missing owner, or no single
    /// active route for the session.
    case invalidConfiguration
    /// The control service failed to start. `description` is the
    /// operator-facing text of the error
    /// (``TerminalTelegramControlError/operatorDescription(_:)``), with any
    /// bot token removed; the companion also records it as the control
    /// state's `lastError`.
    case controlFailed(description: String)

    /// The text the primary channel writes on its failure channel.
    var failureText: String {
        switch self {
        case .notPaired:
            "ZenCODE: Telegram is not paired. Run the /setup command in zen.\n"
        case .invalidConfiguration:
            "ZenCODE: Telegram configuration is invalid. Run /setup to pair Telegram again.\n"
        case let .controlFailed(description):
            "ZenCODE: \(description)\n"
        }
    }
}
