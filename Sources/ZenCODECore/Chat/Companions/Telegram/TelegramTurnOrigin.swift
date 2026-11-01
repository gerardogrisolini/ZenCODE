//
//  TelegramTurnOrigin.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Who sent the turn a ``TelegramSessionCompanion`` follows.
///
/// The companion reaches Telegram only through a validated route lease, so it
/// tells apart just two origins: the session's primary channel, and a linked
/// Telegram chat on one route generation. A route key that was never
/// validated has no place here: the channel resolves and validates it through
/// the router, and gives the companion the lease it obtained.
///
/// The terminal chat keeps its own origin (`TerminalPromptOrigin`) and maps it
/// when it hands a turn to the companion:
///
/// | `TerminalPromptOrigin`            | `TelegramTurnOrigin`        |
/// |-----------------------------------|-----------------------------|
/// | `.local`                          | `.primary`                  |
/// | `.telegramLease(lease)`           | `.telegram(lease)`          |
/// | `.telegram(chatID:)`              | `nil` (no origin)           |
/// | `.telegramRoute(_:)`              | `nil` (no origin)           |
///
/// The last two carry no validated lease. The terminal's Telegram egress
/// already treats them as unlinked and fails closed (nothing is sent, no
/// permission is asked, `/telegram on` does not adopt them), which is what
/// the companion does without an origin. No production path builds them.
enum TelegramTurnOrigin: Sendable, Equatable {
    /// The session's primary channel (the terminal, the app, or an ACP
    /// client). `attach()` moves a turn of this origin that is already
    /// running onto the route it validated, so that turn can be mirrored too.
    case primary
    /// A linked Telegram chat, on the route generation `lease` validated.
    case telegram(TerminalTelegramRouteLease)

    /// The route lease of a Telegram origin; `nil` for ``primary``.
    var lease: TerminalTelegramRouteLease? {
        guard case let .telegram(lease) = self else { return nil }
        return lease
    }
}
