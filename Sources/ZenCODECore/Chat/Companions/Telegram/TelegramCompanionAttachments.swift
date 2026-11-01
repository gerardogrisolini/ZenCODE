//
//  TelegramCompanionAttachments.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The Telegram companions attached in this process, per bot.
///
/// Each companion links its session through a control service of its own,
/// but several sessions can serve the same bot, for example the sessions of
/// one ACP bridge. The registry tells a companion how many are attached to
/// its bot, so it can tell when a message on the route they share (General,
/// an unknown topic, the legacy route) cannot be attributed to one session.
///
/// The key is the bot's `id` as `getMe` reported it when the companion's
/// control service started (``TerminalTelegramControlState/botID``). A
/// companion is registered while its control service is active: a successful
/// ``TelegramSessionCompanion/attach()`` registers it, while
/// ``TelegramSessionCompanion/detach()``,
/// ``TelegramSessionCompanion/shutdown()``, and an attach that fails remove
/// it. Registration follows object identity, so attaching twice counts once,
/// and a companion is under one bot at a time. The registry holds companions
/// weakly: one released without being detached no longer counts.
@ChatSessionActor
final class TelegramCompanionAttachments {
    /// The registry of the process, which companions use by default.
    static let shared = TelegramCompanionAttachments()

    private struct Entry {
        weak var companion: TelegramSessionCompanion?
    }

    private var entriesByBotID: [Int64: [Entry]] = [:]

    /// An empty registry. Production uses ``shared``; a test passes its own
    /// to every companion it creates.
    init() {}

    /// Registers `companion` under `botID`, removing it from any bot it was
    /// registered under before. Registering it again under the same bot
    /// changes nothing.
    func register(_ companion: TelegramSessionCompanion, botID: Int64) {
        unregister(companion)
        entriesByBotID[botID, default: []].append(Entry(companion: companion))
    }

    /// Removes `companion` from the registry. Removing a companion that is
    /// not registered changes nothing.
    func unregister(_ companion: TelegramSessionCompanion) {
        for botID in Array(entriesByBotID.keys) {
            let entries = entriesByBotID[botID, default: []].filter {
                guard let registered = $0.companion else { return false }
                return registered !== companion
            }
            entriesByBotID[botID] = entries.isEmpty ? nil : entries
        }
    }

    /// The number of companions attached to the bot `botID`.
    func attachedCount(botID: Int64) -> Int {
        entriesByBotID[botID, default: []].count(where: { $0.companion != nil })
    }
}
