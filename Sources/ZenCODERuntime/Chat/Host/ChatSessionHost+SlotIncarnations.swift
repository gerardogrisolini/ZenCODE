//
//  ChatSessionHost+SlotIncarnations.swift
//  ZenCODE
//
//  What the host tells about its open slots: their ids, the incarnation and
//  reducer each slot runs now, and the observers and streams of its
//  incarnation changes.
//

import Foundation

extension ChatSessionHost {
    /// The open slots, in no particular order.
    var slotIDs: [ChatSlotID] {
        Array(slots.keys)
    }

    /// The session `slotID` runs now, as the host knows it at this moment;
    /// `nil` for an unknown slot or a slot without session.
    public func incarnation(in slotID: ChatSlotID) -> ChatSessionIncarnation? {
        slots[slotID]?.incarnation
    }

    /// The reducer of the session `slotID` runs now, when the slot publishes
    /// state or Telegram drives it.
    public func reducer(in slotID: ChatSlotID) -> ChatSessionStateReducer? {
        slots[slotID]?.incarnation?.reducer
    }

    /// Registers `observer`, called after every change of the slot's
    /// incarnation with the new one (or `nil`), and returns its token; `nil`
    /// for an unknown slot. The observer is not called for the current
    /// incarnation.
    @discardableResult
    package func addIncarnationObserver(
        to slotID: ChatSlotID,
        _ observer: @escaping @ChatSessionActor (ChatSessionIncarnation?) -> Void
    ) -> UUID? {
        guard let slot = slots[slotID] else { return nil }
        let token = UUID()
        slot.incarnationObservers[token] = observer
        return token
    }

    /// A stream of the incarnations of `slotID`: the current one at once
    /// (`nil` between sessions), then each new one. Like a reducer's
    /// snapshots, a slow consumer skips to the newest. The stream ends when
    /// the consumer stops iterating, when the slot closes, or on shutdown;
    /// for an unknown slot it ends at once.
    public func incarnations(in slotID: ChatSlotID) -> AsyncStream<ChatSessionIncarnation?> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ChatSessionIncarnation?.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        guard let slot = slots[slotID] else {
            continuation.finish()
            return stream
        }
        let token = UUID()
        continuation.yield(slot.incarnation)
        slot.incarnationObservers[token] = { incarnation in
            continuation.yield(incarnation)
        }
        slot.incarnationStreams[token] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @ChatSessionActor in
                guard let slot = self.slots[slotID] else { return }
                slot.incarnationObservers.removeValue(forKey: token)
                slot.incarnationStreams.removeValue(forKey: token)
            }
        }
        return stream
    }
}
