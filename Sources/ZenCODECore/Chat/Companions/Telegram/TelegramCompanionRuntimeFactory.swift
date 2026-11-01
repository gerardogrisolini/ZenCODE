//
//  TelegramCompanionRuntimeFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The public construction points of what a ``TelegramSessionCompanion``
/// runs on: the route authority and the control service.
///
/// The terminal and the ACP bridge build their router here, so every channel
/// resolves and persists the Telegram routes the same way. A host app builds
/// both here and passes them to
/// ``TelegramSessionCompanion/init(controller:sessionRunner:router:controlService:channel:configuration:)``.
public enum TelegramCompanionRuntimeFactory {
    /// The route authority of the Telegram link in `settings`: the linked
    /// chat, its owner, and the persisted routes. Every route change is saved
    /// back to the settings
    /// (``AgentSettingsManifestStore/saveTelegramRoutes(_:ownerUserID:)``).
    ///
    /// A process that runs several sessions builds one router and shares it
    /// among their companions, as the ACP bridge does, so a route one
    /// session changes is the route the others validate.
    public static func makeRouter(
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

    /// A control service of one companion, on the production Bot API
    /// transport and the process-wide poller.
    public static func makeControlService() -> TerminalTelegramControlService {
        TerminalTelegramControlService()
    }
}
