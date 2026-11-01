//
//  TelegramSessionCompanion+Consent.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The decision one consent channel reached in the race of
/// ``TelegramSessionCompanion/authorizeToolRequest(_:origin:)``.
private enum TelegramConsentChannelResult: Sendable {
    case primary(ChatToolConsentAuthorizer.AuthorizationOutcome)
    case telegram(TerminalTelegramPermissionOutcome)
}

extension TelegramSessionCompanion {
    /// The authorization handler of a turn of `origin` mirrored to Telegram,
    /// or `nil` when the turn does not reach the linked chat, in which case
    /// the turn keeps the runner's default authorization.
    ///
    /// `origin` is routed like ``beginTurn(origin:mirrorEpoch:)`` routes it
    /// (see ``routedOrigin(for:)``), so a turn of the primary channel is
    /// asked in the linked chat too while the link is active. The handler
    /// holds the companion weakly and refuses once it is gone.
    func toolAuthorizationHandler(
        for origin: TelegramTurnOrigin
    ) -> AgentToolAuthorizationHandler? {
        let origin = routedOrigin(for: origin)
        guard outgoingChatID(for: origin) != nil else {
            return nil
        }
        return { [weak self] request in
            guard let self else {
                return false
            }
            return await self.authorizeToolRequest(request, origin: origin)
        }
    }

    /// Authorizes a gated tool call of a turn mirrored to Telegram.
    ///
    /// Only the tools ``ChatToolConsentAuthorizer/gatedToolNames`` gates are
    /// asked; every other tool runs. A request that neither the controller's
    /// authorizer nor the linked chat already covers is asked on both at
    /// once, whatever the turn's origin: the primary channel through
    /// ``ChatSessionController/authorizer`` and the linked chat through
    /// ``permissionBroker``. The first explicit decision wins and the other
    /// request is cancelled. A channel that cannot decide (unavailable,
    /// cancelled, timed out, undeliverable) leaves the decision to the other;
    /// when neither decides, the call is denied. An origin without a linked
    /// chat cannot ask Telegram, so its call is denied.
    ///
    /// A `/always` in the linked chat is also recorded in the controller's
    /// authorizer (``ChatToolConsentAuthorizer/recordAlwaysDecision(for:)``),
    /// as an *Always* given in the primary channel: it keeps covering later
    /// turns of the session after ``detach()`` or a topic change, and a
    /// `local.exec` approval is saved.
    ///
    /// The primary channel is told, through
    /// ``TelegramCompanionChannel/presentCompanionNotice(_:channel:)``, that
    /// the permission is required and how the linked chat decided; the linked
    /// chat is told how the primary channel decided. The texts are the
    /// terminal's, naming where the primary channel asks
    /// (``Configuration/consentLocationDescription``).
    func authorizeToolRequest(
        _ request: AgentToolAuthorizationRequest,
        origin: TelegramTurnOrigin
    ) async -> Bool {
        guard ChatToolConsentAuthorizer.gatedToolNames.contains(request.toolName) else {
            return true
        }

        guard let lease = origin.lease,
              let chatID = outgoingChatID(for: origin) else {
            await channel?.presentCompanionNotice(
                "ZenCODE: Telegram cannot request permission for \(request.toolName); the operation was denied.\n",
                channel: .failure
            )
            return false
        }

        let authorizer = controller.authorizer
        let primaryAlreadyAuthorized = await authorizer.isAlreadyAuthorized(request)
        guard (try? await router.validate(lease)) != nil else { return false }
        let telegramAlreadyAuthorized = await permissionBroker.isAlreadyAuthorized(
            request, lease: lease
        )
        if primaryAlreadyAuthorized || telegramAlreadyAuthorized {
            return true
        }
        await channel?.presentCompanionNotice(
            Self.permissionPendingText(
                for: request,
                consentLocation: configuration.consentLocationDescription
            ),
            channel: .system
        )

        let winningResult = await withTaskGroup(
            of: TelegramConsentChannelResult.self,
            returning: TelegramConsentChannelResult?.self
        ) { group in
            group.addTask {
                .primary(await authorizer.authorizationOutcome(for: request))
            }
            group.addTask { [weak self, permissionBroker] in
                let send: @Sendable (String) async -> Bool = { [weak self] message in
                    guard let self, await self.validateOrigin(origin) else { return false }
                    return await self.sendTurnMessage(
                        .authorization(message), to: chatID, origin: origin
                    )
                }
                let outcome = await permissionBroker.authorize(
                    request, lease: lease, sendMessage: send
                )
                return .telegram(outcome)
            }

            while let result = await group.next() {
                switch result {
                case let .primary(outcome):
                    switch outcome {
                    case .allowedOnce, .allowedAlways, .denied:
                        group.cancelAll()
                        return result
                    case .unavailable, .cancelled:
                        continue
                    }
                case let .telegram(outcome):
                    switch outcome {
                    case .notRequired, .allowedOnce, .allowedAlways, .denied:
                        group.cancelAll()
                        return result
                    case .timedOut, .undeliverable, .cancelled:
                        continue
                    }
                }
            }
            return nil
        }

        switch winningResult {
        case let .primary(outcome):
            let approved = outcome.isApproved
            await sendTurnMessage(
                .authorization(
                    Self.primaryConsentDecisionText(
                        approved: approved,
                        toolName: request.toolName,
                        consentLocation: configuration.consentLocationDescription
                    )
                ),
                to: chatID,
                origin: origin
            )
            return approved
        case let .telegram(outcome):
            if outcome == .allowedAlways {
                // Like an Always given in the primary channel, so it keeps
                // covering the session after the link or the topic changes.
                await authorizer.recordAlwaysDecision(for: request)
            }
            await presentTelegramPermissionOutcome(outcome, request: request)
            return outcome.isApproved
        case nil:
            await channel?.presentCompanionNotice(
                "ZenCODE: no authorization channel could resolve \(request.toolName); the operation was denied.\n",
                channel: .failure
            )
            return false
        }
    }

    /// Answers a permission reply (`/allow`, `/always`, `/deny`) that
    /// arrived on `lease`, returning `true` when the text was a permission
    /// reply or a reply to a pending permission request, so it must not run
    /// as a prompt. A reply on a route that is no longer valid is consumed
    /// without effect. The broker's answer goes to the linked chat on the
    /// turn's ordered channel.
    func handlePermissionResponseIfNeeded(
        _ text: String,
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        guard (try? await router.validate(lease)) != nil else { return true }
        let result = await permissionBroker.handleMessage(text, lease: lease)
        switch result {
        case .notHandled:
            return false
        case let .handled(reply):
            if let reply = reply?.nilIfBlank {
                await sendTurnMessage(
                    .authorization(reply), to: lease.key.chatID,
                    origin: .telegram(lease)
                )
            }
            return true
        }
    }

    /// The notice that a permission is waiting for a decision on either
    /// channel. `consentLocation` is where the primary channel asks
    /// (``Configuration/consentLocationDescription``).
    nonisolated static func permissionPendingText(
        for request: AgentToolAuthorizationRequest,
        consentLocation: String
    ) -> String {
        """

        Permission required: \(request.title)
        Approve or deny in \(consentLocation), or use /allow, /always or /deny in the linked chat.

        """
    }

    /// The text the linked chat receives when the primary channel decided a
    /// permission first. `consentLocation` is where it asked
    /// (``Configuration/consentLocationDescription``): "the terminal" gives
    /// the terminal's texts, "the editor" those of an ACP session.
    nonisolated static func primaryConsentDecisionText(
        approved: Bool,
        toolName: String,
        consentLocation: String
    ) -> String {
        approved
            ? "✅ Permission granted in \(consentLocation) for \(toolName). Continuing."
            : "⛔ Permission denied in \(consentLocation) for \(toolName)."
    }

    /// Tells the primary channel how the linked chat decided.
    private func presentTelegramPermissionOutcome(
        _ outcome: TerminalTelegramPermissionOutcome,
        request: AgentToolAuthorizationRequest
    ) async {
        switch outcome {
        case .notRequired:
            // A previous decision already covered the request; nothing was asked.
            break
        case .allowedOnce, .allowedAlways:
            await channel?.presentCompanionNotice(
                "Telegram approved \(request.toolName).\n",
                channel: .system
            )
        case .denied:
            await channel?.presentCompanionNotice(
                "Telegram denied \(request.toolName).\n",
                channel: .system
            )
        case .timedOut:
            await channel?.presentCompanionNotice(
                "ZenCODE: Telegram permission for \(request.toolName) timed out; the operation was denied.\n",
                channel: .failure
            )
        case .undeliverable:
            await channel?.presentCompanionNotice(
                "ZenCODE: the Telegram permission request for \(request.toolName) could not be delivered; the operation was denied.\n",
                channel: .failure
            )
        case .cancelled:
            break
        }
    }
}
