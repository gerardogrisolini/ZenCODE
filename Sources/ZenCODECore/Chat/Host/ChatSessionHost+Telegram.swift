//
//  ChatSessionHost+Telegram.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation

/// What the Telegram channels of every slot share: one route authority and
/// one Bot API poller per process (see `ChatSessionHost+Channels.swift` for
/// the channels themselves and the handover of a slot).
///
/// One router keeps the routes of several sessions in one consistent set, so
/// no session overwrites the topic another one created; it is created from
/// the persisted settings on first use and writes them back through
/// `AgentSettingsManifestStore.saveTelegramRoutes`. Each channel has a
/// control service of its own, but a service that brought its own dispatcher
/// would start its own long poll: two `getUpdates` on one bot make Telegram
/// answer HTTP 409 to one of them. Through one dispatcher a bot has exactly
/// one long poll, whose updates are broadcast to every service, which applies
/// its own route checks. An app that embeds the host gets both through
/// ``activateTelegram(in:primaryChannelDescription:)``, which creates the
/// slot's channel on them; nothing is built outside the host.
extension ChatSessionHost {
    /// The router every Telegram channel of this host resolves its routes
    /// with, created on first use from the settings as they are then.
    func telegramRouter() -> TerminalTelegramSessionRouter {
        if let router = telegramRouterStorage {
            return router
        }
        let router = Self.makeTelegramRouter()
        telegramRouterStorage = router
        return router
    }

    /// The route authority of the Telegram link in `settings`: the linked
    /// chat, its owner, and the persisted routes. Every route change is saved
    /// back to the settings
    /// (``AgentSettingsManifestStore/saveTelegramRoutes(_:ownerUserID:)``).
    static func makeTelegramRouter(
        settings: AgentTelegramSettingsManifest? = AgentSettingsManifestStore.load()?.telegram
    ) -> TerminalTelegramSessionRouter {
        TerminalTelegramSessionRouter(
            linkedChatID: settings?.linkedChatID,
            ownerUserID: settings?.ownerUserID,
            routes: settings?.routes ?? [],
            persist: { ownerUserID, routes in
                try AgentSettingsManifestStore.saveTelegramRoutes(routes, ownerUserID: ownerUserID)
            }
        )
    }

    /// The poller every channel's control service subscribes through,
    /// created with the router.
    func telegramDispatcher() -> TerminalTelegramBotDispatcher {
        if let dispatcher = telegramDispatcherStorage {
            return dispatcher
        }
        let dispatcher = TerminalTelegramBotDispatcher()
        telegramDispatcherStorage = dispatcher
        return dispatcher
    }
}
