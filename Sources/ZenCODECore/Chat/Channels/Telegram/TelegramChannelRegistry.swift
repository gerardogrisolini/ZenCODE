//
//  TelegramChannelRegistry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The Telegram channels attached in this process, per bot.
///
/// Each channel links its slot's session through a control service of its
/// own, but several sessions can serve the same bot, for example the
/// sessions of one ACP bridge. The registry tells a channel how many are
/// attached to its bot, so it can tell when a message on the route they share
/// (General, an unknown topic, the legacy route) cannot be attributed to one
/// session.
///
/// The key is the bot's `id` as `getMe` reported it when the channel's
/// control service started (``TerminalTelegramControlState/botID``). A
/// channel is registered while its control service is active: a successful
/// ``TelegramChannel/attach()`` registers it, while ``TelegramChannel/detach()``,
/// ``TelegramChannel/shutdown()``, and an attach that fails remove it.
/// Registration follows object identity, so attaching twice counts once, and
/// a channel is under one bot at a time. The registry holds channels weakly:
/// one released without being detached no longer counts.
@ChatSessionActor
final class TelegramChannelRegistry {
    /// The registry of the process, which channels use by default.
    static let shared = TelegramChannelRegistry()

    private struct Entry {
        weak var channel: TelegramChannel?
    }

    private var entriesByBotID: [Int64: [Entry]] = [:]

    /// An empty registry. Production uses ``shared``; a test passes its own
    /// to every channel it creates.
    init() {}

    /// Registers `channel` under `botID`, removing it from any bot it was
    /// registered under before. Registering it again under the same bot
    /// changes nothing.
    func register(_ channel: TelegramChannel, botID: Int64) {
        unregister(channel)
        entriesByBotID[botID, default: []].append(Entry(channel: channel))
    }

    /// Removes `channel` from the registry. Removing a channel that is not
    /// registered changes nothing.
    func unregister(_ channel: TelegramChannel) {
        for botID in Array(entriesByBotID.keys) {
            let entries = entriesByBotID[botID, default: []].filter {
                guard let registered = $0.channel else { return false }
                return registered !== channel
            }
            entriesByBotID[botID] = entries.isEmpty ? nil : entries
        }
    }

    /// The number of channels attached to the bot `botID`.
    func attachedCount(botID: Int64) -> Int {
        entriesByBotID[botID, default: []].count(where: { $0.channel != nil })
    }
}
