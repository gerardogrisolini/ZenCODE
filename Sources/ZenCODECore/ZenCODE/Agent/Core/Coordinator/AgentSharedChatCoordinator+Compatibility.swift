//
//  AgentSharedChatCoordinator+Compatibility.swift
//  ZenCODE
//

import Foundation

/// Source-compatibility layer for the room-scoped shared-chat coordination API.
///
/// The first shape of this API keyed busy state and turn claims by *room*:
/// `observe(roomID:)` returned a bare stream and any caller could declare the
/// room busy or claim its trigger. That model could not express two live
/// consumers of one room, so the supported API is now keyed by
/// ``AgentSharedChatCoordinator/Observation``.
///
/// `Docs/architecture.md` is the compatibility contract for public surface, so
/// the removed spellings are kept here as deprecated forwarders instead of
/// disappearing: source consumers keep compiling, and the compiler tells them
/// exactly which call to migrate to. They are implemented on top of the same
/// atomic primitives as the supported API — a legacy claim is granted through a
/// real observation identity, never through a room-wide back door — so a legacy
/// caller cannot reintroduce the concurrent-turn race the observation model
/// fixed.
public extension AgentSharedChatCoordinator {
    /// Subscribes to live coordination events without an observer identity.
    ///
    /// The returned stream is a real observation: its events are identical to
    /// ``observeSubscription(roomID:)`` and terminating it detaches the
    /// observer. The identity is retained internally so the deprecated
    /// room-scoped busy and claim calls below can act on behalf of the most
    /// recent legacy observer of that room, which is exactly the single-consumer
    /// model this API assumed.
    @available(
        *,
        deprecated,
        renamed: "observeSubscription(roomID:)",
        message: """
        Room-scoped observation cannot express two live consumers. \
        Use observeSubscription(roomID:) and keep its Observation to declare \
        busy state, claim triggers and detach.
        """
    )
    func observe(roomID rawRoomID: String) -> AsyncStream<AgentSharedChatCoordinatorEvent> {
        let observation = observeSubscription(roomID: rawRoomID)
        registerLegacyObservation(observation)
        return observation.events
    }

    /// Declares consumer-side activity for the room's legacy observer.
    ///
    /// Without a legacy observation the call is a no-op by design: a busy
    /// declaration that belongs to nobody could never be released, and the
    /// coordinator only authorises turns for attached observers anyway.
    @available(
        *,
        deprecated,
        renamed: "setConsumerBusy(_:observation:)",
        message: """
        Busy state is per observer. Pass the Observation returned by \
        observeSubscription(roomID:).
        """
    )
    func setConsumerBusy(_ isBusy: Bool, roomID rawRoomID: String) {
        guard let observation = legacyObservation(roomID: rawRoomID) else { return }
        setConsumerBusy(isBusy, observation: observation)
    }

    /// Answers a trigger on behalf of the room's legacy observer.
    ///
    /// `declined` never needs an identity: it falls back to the ownerless
    /// ``declineAutoTrigger(id:roomID:)``, which only ever returns an unclaimed
    /// batch to the queue. `started` does need one, because a claim is
    /// ownership: without a legacy observation the call reports `notAcquired`
    /// rather than granting an unattributable turn.
    @available(
        *,
        deprecated,
        renamed: "resolveAutoTrigger(id:observation:resolution:)",
        message: """
        Claims are owner-bound. Pass the Observation returned by \
        observeSubscription(roomID:); a claim without an observer identity is \
        reported as notAcquired.
        """
    )
    @discardableResult
    func resolveAutoTrigger(
        id: UUID,
        roomID rawRoomID: String,
        resolution: AgentSharedChatAutoTriggerResolution
    ) -> AgentSharedChatAutoTriggerClaimResult {
        guard let observation = legacyObservation(roomID: rawRoomID) else {
            if resolution == .declined {
                declineAutoTrigger(id: id, roomID: rawRoomID)
            }
            return .notAcquired
        }
        return resolveAutoTrigger(id: id, observation: observation, resolution: resolution)
    }
}
