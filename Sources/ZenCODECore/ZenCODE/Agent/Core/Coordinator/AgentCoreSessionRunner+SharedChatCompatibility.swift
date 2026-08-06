//
//  AgentCoreSessionRunner+SharedChatCompatibility.swift
//  ZenCODE
//

import Foundation

/// Source-compatibility layer for the room-scoped shared-chat API of the Core
/// session runner.
///
/// These spellings predate ``AgentSharedChatCoordinator/Observation``: they
/// assumed a single consumer per room, so busy state and turn claims were keyed
/// by session id. `Docs/architecture.md` keeps public surface compatible unless
/// an explicit migration removes it, so they remain here as deprecated
/// forwarders onto the observation-based coordinator API. Each one carries the
/// exact replacement call, and none of them can grant a turn without an
/// observer identity.
public extension AgentCoreSessionRunner {
    /// Subscribes to live shared-chat coordination without keeping an
    /// observation. Use ``attachSharedChatObservation(rootSessionID:)`` to get
    /// the identity required to declare busy state, claim triggers and detach.
    @available(
        *,
        deprecated,
        renamed: "attachSharedChatObservation(rootSessionID:)",
        message: """
        Room-scoped observation cannot express two live consumers. \
        Use attachSharedChatObservation(rootSessionID:) and keep its \
        Observation for busy state, claims and detach.
        """
    )
    func observeSharedChat(
        rootSessionID: String
    ) async -> AsyncStream<AgentSharedChatCoordinatorEvent> {
        await sharedChatCoordinator().observe(roomID: rootSessionID)
    }

    /// Declares consumer-side activity for the room's legacy observer.
    @available(
        *,
        deprecated,
        renamed: "setSharedChatConsumerBusy(_:observation:)",
        message: """
        Busy state is per observer. Pass the Observation returned by \
        attachSharedChatObservation(rootSessionID:).
        """
    )
    func setSharedChatConsumerBusy(
        _ isBusy: Bool,
        rootSessionID: String
    ) async {
        await sharedChatCoordinator().setConsumerBusy(isBusy, roomID: rootSessionID)
    }

    /// Answers a trigger on behalf of the room's legacy observer. A `started`
    /// resolution without a legacy observation reports `notAcquired` instead of
    /// granting an unattributable turn; `declined` still returns the batch.
    @available(
        *,
        deprecated,
        renamed: "resolveSharedChatAutoTrigger(id:observation:resolution:)",
        message: """
        Claims are owner-bound. Pass the Observation returned by \
        attachSharedChatObservation(rootSessionID:); a claim without an \
        observer identity is reported as notAcquired.
        """
    )
    @discardableResult
    func resolveSharedChatAutoTrigger(
        id: UUID,
        rootSessionID: String,
        resolution: AgentSharedChatAutoTriggerResolution
    ) async -> AgentSharedChatAutoTriggerClaimResult {
        await sharedChatCoordinator().resolveAutoTrigger(
            id: id,
            roomID: rootSessionID,
            resolution: resolution
        )
    }
}
