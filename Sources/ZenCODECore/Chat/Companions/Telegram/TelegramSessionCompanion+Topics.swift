//
//  TelegramSessionCompanion+Topics.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Topic mode and legacy mode: which route of the linked private chat the
/// session uses.
///
/// ``attach()`` tries, in order:
/// 1. **Reuse.** The router still has an active route with a topic for this
///    session (`activeRoute(forRoomID:)`, the highest topic wins): the
///    session keeps that topic, resolved through the router.
/// 2. **Creation.** Otherwise, when the bot has Threaded mode
///    (``TerminalTelegramControlState/hasTopicsEnabled``), the session gets a
///    topic of its own, named ``defaultTopicName(workingDirectory:sessionID:)``,
///    and a route bound to its session ID. General receives
///    ``generalTopicNoticeText(topicName:)`` once.
/// 3. **Legacy.** Otherwise the session uses the one active route without a
///    topic whose room is the session or every session (`default`), shared by
///    every attached session: no notice, no exclusivity, as before topics.
///
/// Threaded mode is known only once the control service started (`getMe`),
/// and creating a topic needs the started lifecycle's wire fence, so the
/// route is resolved in two steps: ``egressRoute(settings:linkedChatID:)``
/// resolves the reused topic or the shared route before the service starts,
/// so an unusable configuration still fails before any request, and
/// ``createSessionTopicIfNeeded(for:)`` creates the topic right after the
/// start, under the fence of the shared route the request starts from. A
/// creation that fails falls back to legacy mode; its error is recorded as
/// the control state's `lastError` and presented on the primary channel
/// after the activation text, like a poll-health notice. An attach that a
/// later lifecycle operation overtook while the topic was being created
/// leaves the new route active and unowned: the next attach reuses it.
///
/// The notice in General is sent only when the topic is *created*, never
/// when it is reused, so it is given once per topic without persisting
/// anything: `settings.json` keeps its format. A topic name is not persisted
/// either: a reused topic is shown with its default name, a topic the
/// companion renamed with the name it gave.
///
/// While the session is in topic mode, ``rebind(sessionID:displayName:)``
/// moves its topic to the session the channel switched to, and
/// ``detach()`` and ``shutdown()`` close the topic's route and prune the
/// inactive routes beyond ``retainedInactiveTopicLimit`` (no topic is
/// deleted on Telegram, which cannot close a topic of a private chat). Reuse
/// covers only active routes, so after `/telegram off` and `on`, or at a new
/// launch, the session receives a new topic; nothing is written in the old
/// one any more, and it stays in Telegram. A turn that runs across such a
/// detach and attach stays on the closed route, so nothing more of it is
/// mirrored; the next turn uses the new topic. In legacy mode none of these
/// operations writes anything, as before topics.
///
/// The router keeps one route per topic: a `create` after a prune starts
/// again from generation 1, which is safe because Telegram never reuses a
/// topic ID and only active routes are reused here.
///
/// The ingress (`TelegramSessionCompanion+Ingress.swift`) follows the mode:
/// a message in the session's topic is answered by this session only; a
/// message in General, in a topic no route knows (which falls back to the
/// shared route), or on the legacy route is answered by every attached
/// companion, in the topic it came from, with the permission replies without
/// an ID refused while several companions share the bot. In topic mode such
/// a message leaves the link, the shared-chat relay, and the next turn of the
/// primary channel on the session's topic; in legacy mode it moves them onto
/// its route, as before topics.
extension TelegramSessionCompanion {
    /// The session's own topic while the link is in topic mode.
    public struct SessionTopic: Sendable, Equatable {
        /// The current lease of the topic's route.
        public var lease: TerminalTelegramRouteLease
        /// The topic's name, as the companion last gave it, bounded like the
        /// name Telegram stores.
        public var name: String
    }

    /// The route ``attach()`` resolves before the control service starts
    /// (see ``egressRoute(settings:linkedChatID:)``).
    enum EgressRoute: Sendable, Equatable {
        /// The session's topic, still active from an earlier link: reused.
        case sessionTopic(TerminalTelegramRouteLease)
        /// The route without a topic every session shares (General, or the
        /// legacy route): the session stays there, or creates its topic from
        /// there.
        case shared(TerminalTelegramRouteLease)

        var lease: TerminalTelegramRouteLease {
            switch self {
            case let .sessionTopic(lease), let .shared(lease): lease
            }
        }
    }

    /// What ``createSessionTopicIfNeeded(for:)`` did.
    enum TopicCreation: Sendable, Equatable {
        /// The topic was created and its route bound to the session; the
        /// shared route is the one the notice in General is sent on.
        case created(SessionTopic, shared: TerminalTelegramRouteLease)
        /// The creation failed with this operator-facing description; the
        /// session stays in legacy mode.
        case failed(String)
    }

    /// How many routes that are no longer active (`.closed`, `.deleted`)
    /// stay in the settings once a topic is closed.
    static let retainedInactiveTopicLimit = 32

    // MARK: - Texts

    /// The name a session's topic is created with: the working directory's
    /// last component and the last eight characters of the session ID,
    /// bounded like the name Telegram stores (128 UTF-16 units, cut on
    /// grapheme boundaries). The channel passes the same name to
    /// ``rebind(sessionID:displayName:)`` for a session that was never saved.
    nonisolated static func defaultTopicName(workingDirectory: URL, sessionID: String) -> String {
        TerminalTelegramAPIClient.boundedTopicName(
            "\(workingDirectory.lastPathComponent) · \(sessionID.suffix(8))"
        )
    }

    /// The notice sent in General when the session's topic is created.
    nonisolated static func generalTopicNoticeText(topicName: String) -> String {
        "ZenCODE session “\(topicName)” now has its own topic; messages sent here in General reach every attached session."
    }

    // MARK: - Attach

    /// Restores the owner-bearing route persisted by setup, so ``attach()``
    /// enables egress at once, without waiting for a Telegram message: the
    /// session's topic when the router still has it active, otherwise the
    /// shared route.
    ///
    /// The route is resolved through the owner authority rather than built
    /// from `linkedChatID`, so every later wire operation keeps the
    /// generation and lifecycle validation of multi-session routing. The
    /// shared route must be the one active route without a topic that
    /// belongs to this session or to every session (`default`), exactly as
    /// before topics. `nil` when the settings are unsupported, ownerless,
    /// or incoherent.
    func egressRoute(
        settings: AgentTelegramSettingsManifest,
        linkedChatID: Int64
    ) async -> EgressRoute? {
        guard settings.isRoutingSupported else { return nil }
        await router.refresh(
            linkedChatID: settings.linkedChatID,
            ownerUserID: settings.ownerUserID,
            routes: settings.routes
        )
        guard settings.linkedChatID == linkedChatID,
              let ownerUserID = settings.ownerUserID else { return nil }
        let sessionID = controller.sessionID
        if let topicID = await router.activeRoute(forRoomID: sessionID)?.topicID,
           let lease = try? await router.resolve(
               chatID: linkedChatID, userID: ownerUserID, topicID: topicID
           ),
           lease.key.topicID == topicID {
            return .sessionTopic(lease)
        }
        let candidates = settings.routes.filter {
            $0.topicID == nil
                && $0.lifecycle == .active
                && ($0.roomID == sessionID || $0.roomID == "default")
        }
        guard candidates.count == 1,
              let lease = try? await router.resolve(
                  chatID: linkedChatID, userID: ownerUserID, topicID: nil
              ) else { return nil }
        return .shared(lease)
    }

    /// The session's topic as ``attach()`` records it before the service
    /// starts: the reused topic, keeping the name the companion gave it when
    /// it is the topic the link already had, or none on the shared route.
    func recordedSessionTopic(for route: EgressRoute) -> SessionTopic? {
        guard case let .sessionTopic(lease) = route else { return nil }
        if let current = sessionTopic, current.lease == lease {
            return current
        }
        return SessionTopic(
            lease: lease,
            name: Self.defaultTopicName(
                workingDirectory: controller.workingDirectory, sessionID: controller.sessionID
            )
        )
    }

    /// Creates the session's topic once the control service started, when
    /// `route` is the shared route and the bot has Threaded mode; `nil`
    /// otherwise. The request is fenced by the shared route; the new route
    /// is bound to the session ID. Nothing of the companion's state changes:
    /// ``attach()`` applies the outcome with ``adoptTopicCreation(_:)`` if it
    /// was not overtaken meanwhile.
    func createSessionTopicIfNeeded(for route: EgressRoute) async -> TopicCreation? {
        guard case let .shared(shared) = route,
              controlState.hasTopicsEnabled == true else { return nil }
        let name = Self.defaultTopicName(
            workingDirectory: controller.workingDirectory, sessionID: controller.sessionID
        )
        do {
            guard let fence = wireFence(for: .telegram(shared)) else {
                throw TerminalTelegramControlError.missingConfiguration
            }
            let topicID = try await controlService.createTopic(
                name: name, chatID: shared.key.chatID, fence: fence
            )
            let lease = try await router.create(topicID: topicID, roomID: controller.sessionID)
            return .created(SessionTopic(lease: lease, name: name), shared: shared)
        } catch {
            return .failed(TerminalTelegramControlError.operatorDescription(error))
        }
    }

    /// Applies a topic creation: a created topic becomes the link's route;
    /// a failure is recorded as the control state's `lastError`.
    func adoptTopicCreation(_ creation: TopicCreation) {
        switch creation {
        case let .created(topic, _):
            sessionTopic = topic
            activeRouteLease = topic.lease
        case let .failed(description):
            controlState.lastError = description
        }
    }

    /// Completes a topic creation once the activation text was presented:
    /// a created topic is announced in General, on the shared route; a
    /// failure is presented on the primary channel.
    func announceTopicCreation(_ creation: TopicCreation) async {
        switch creation {
        case let .created(topic, shared):
            guard let fence = wireFence(for: .telegram(shared)) else { return }
            await sendSystemMessage(
                Self.generalTopicNoticeText(topicName: topic.name),
                to: shared.key.chatID, topicID: nil, fence: fence
            )
        case let .failed(description):
            await presentTopicFailure(description)
        }
    }

    // MARK: - Rebind

    /// Moves the session's topic to the session the channel switched to
    /// (`/sessions new`, `/sessions load`), named `displayName`: the saved
    /// session's name, or ``defaultTopicName(workingDirectory:sessionID:)``
    /// of the new session.
    ///
    /// In topic mode the topic's route is rebound to `sessionID`
    /// (`rebind(_:toRoomID:)`): it keeps its topic, its generation advances,
    /// and the new lease becomes the link's route, so the next turn and the
    /// shared-chat relay use it. The topic is then renamed; its name in
    /// `/telegram status` changes only when Telegram accepts the rename. A
    /// failure is recorded and presented on the primary channel like a
    /// failed creation, and a failed rebind leaves the topic as it was. In
    /// legacy mode, and while detached, nothing happens, as before topics.
    ///
    /// The previous lease fails validation from the rebind on, so nothing
    /// still holding it can write: every send of a turn in progress on it
    /// is fenced off, and its route validation task (polling every 100 ms)
    /// reports the lease through
    /// ``TelegramCompanionChannel/telegramRouteWasInvalidated(_:)``. The
    /// channel stops that turn and calls ``routeWasInvalidated(_:)``, which
    /// ends its reporting and tears down the previous route's state but
    /// keeps the link's new route, which is no longer the invalidated one.
    /// ForceReply receipts of the previous lease are no longer answered. The
    /// channel calls this method before it rebinds the shared-chat relay to
    /// the new room (``rebindSharedChatRelay(roomID:)``).
    public func rebind(sessionID: String, displayName: String) async {
        guard let topic = sessionTopic else { return }
        let rebound: TerminalTelegramRouteLease
        do {
            rebound = try await router.rebind(topic.lease, toRoomID: sessionID)
        } catch {
            let description = TerminalTelegramControlError.operatorDescription(error)
            controlState.lastError = description
            await presentTopicFailure(description)
            return
        }
        // A detach or an attach that ran while the router answered owns the
        // link now.
        guard sessionTopic?.lease == topic.lease else { return }
        sessionTopic = SessionTopic(lease: rebound, name: topic.name)
        activeRouteLease = rebound
        let name = TerminalTelegramAPIClient.boundedTopicName(displayName)
        do {
            guard let topicID = rebound.key.topicID,
                  let fence = wireFence(for: .telegram(rebound)) else {
                throw TerminalTelegramControlError.missingConfiguration
            }
            try await controlService.renameTopic(
                name: displayName, chatID: rebound.key.chatID, topicID: topicID, fence: fence
            )
        } catch {
            let description = TerminalTelegramControlError.operatorDescription(error)
            controlState.lastError = description
            await presentTopicFailure(description)
            return
        }
        if sessionTopic?.lease == rebound {
            sessionTopic?.name = name
        }
    }

    // MARK: - Detach

    /// Closes the session's topic route and prunes the inactive routes
    /// beyond ``retainedInactiveTopicLimit``, when the link is in topic
    /// mode; in legacy mode nothing is written. Best effort: a route another
    /// operation already changed stays as it is. ``detach()`` and
    /// ``shutdown()`` call it once the control service stopped.
    func closeSessionTopic() async {
        guard let topic = sessionTopic else { return }
        sessionTopic = nil
        try? await router.close(topic.lease)
        try? await router.prune(keepingInactive: Self.retainedInactiveTopicLimit)
    }

    // MARK: - Failures

    /// Presents a topic failure on the primary channel, as a failed send is
    /// presented.
    private func presentTopicFailure(_ description: String) async {
        await channel?.presentCompanionNotice("ZenCODE: \(description)\n", channel: .failure)
    }
}
