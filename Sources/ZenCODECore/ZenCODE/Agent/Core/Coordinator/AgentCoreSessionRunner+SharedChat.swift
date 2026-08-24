//
//  AgentCoreSessionRunner+SharedChat.swift
//  ZenCODE
//

import Foundation
import Synchronization
import ToolCore


extension AgentCoreSessionRunner {
    public func closeSubAgent(id: String) async -> Bool {
        guard let backend else { return false }
        return await backend.closeSubAgent(id: id)
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        guard let backend else { return 0 }
        return await backend.interruptSubAgents(rootSessionID: rootSessionID)
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        guard let backend else {
            return []
        }
        return await backend.subAgentSnapshots()
    }

    public func sharedChatParticipants(
        rootSessionID: String
    ) async -> [AgentSharedChat.Participant] {
        guard let backend else { return [] }
        return await backend.sharedChatParticipants(rootSessionID: rootSessionID)
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        guard let backend else { throw AgentSharedChat.Error.unavailable }
        return try await backend.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID
        )
    }

    public func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        guard let backend else { return [] }
        return await backend.drainCoordinatorSharedChatMessages(rootSessionID: rootSessionID)
    }

    public func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        guard let backend else { return [] }
        return await backend.sharedChatTranscriptMessages(rootSessionID: rootSessionID)
    }

    /// The Core auto-trigger. It owns mailbox monitoring, batching and the
    /// idle/busy decision; rendering surfaces are consumers, never owners.
    func sharedChatCoordinator() -> AgentSharedChatCoordinator {
        if let sharedChatCoordinatorStorage {
            return sharedChatCoordinatorStorage
        }
        let coordinator = AgentSharedChatCoordinator(
            source: AgentSharedChatCoordinator.Source(
                drainCoordinatorMessages: { [weak self] roomID in
                    await self?.drainCoordinatorSharedChatMessages(rootSessionID: roomID) ?? []
                },
                participants: { [weak self] roomID in
                    await self?.sharedChatParticipants(rootSessionID: roomID) ?? []
                },
                allRoomMessages: { [weak self] roomID in
                    await self?.sharedChatTranscriptMessages(rootSessionID: roomID) ?? []
                }
            )
        )
        sharedChatCoordinatorStorage = coordinator
        return coordinator
    }

    /// The actor-isolated mention catalogue for this session. Handles are
    /// readable aliases derived from participant names; routing is always by
    /// stable participant id.
    func sharedChatMentionCatalog() -> SharedChatMentionCatalog {
        if let sharedChatMentionCatalogStorage {
            return sharedChatMentionCatalogStorage
        }
        let catalog = SharedChatMentionCatalog()
        sharedChatMentionCatalogStorage = catalog
        return catalog
    }

    /// Returns a handle → participant-id map for the current room roster. Used
    /// by the autocomplete list (display) and the mention parser (routing).
    public func sharedChatMentionHandles(
        rootSessionID: String
    ) async -> [String: String] {
        await sharedChatMentionRoster(rootSessionID: rootSessionID).handleMap
    }

    /// Returns participants and readable handles from one roster snapshot, so a
    /// join/leave between separate backend reads cannot mismatch labels and IDs.
    public func sharedChatMentionRoster(
        rootSessionID: String
    ) async -> (
        participants: [AgentSharedChat.Participant],
        handleMap: [String: String]
    ) {
        let participants = await sharedChatParticipants(rootSessionID: rootSessionID)
        let handleMap = await sharedChatMentionCatalog().handleMap(for: participants)
        return (participants, handleMap)
    }

    /// Resolves a readable mention handle to its stable participant id, or nil
    /// when no live mapping exists.
    public func resolveSharedChatMentionHandle(
        _ handle: String
    ) async -> String? {
        await sharedChatMentionCatalog().participantID(forHandle: handle)
    }

    /// Subscribes to live shared-chat coordination.
    ///
    /// Every consumer — terminal UI, ACP, or a headless driver — receives the
    /// same semantics: `messages` for rendering, `participantsChanged` for
    /// roster refreshes, and `autoTrigger` for the one synthetic turn the Core
    /// authorises at a time. The returned observation is the consumer's
    /// identity: resolve each trigger with
    /// ``resolveSharedChatAutoTrigger(id:observation:resolution:)`` and start a
    /// synthetic prompt only when it returns `acquired`; report consumer-side
    /// activity with ``setSharedChatConsumerBusy(_:observation:)``. Detaching
    /// releases exactly this consumer's busy state and claimed turn.
    public func attachSharedChatObservation(
        rootSessionID: String
    ) async -> AgentSharedChatCoordinator.Observation {
        let coordinator = sharedChatCoordinator()
        if let backend {
            await backend.updateSharedChatMessageAvailableHandler { roomID in
                Task(name: "ZenCODE.shared-chat.transcript-wake") {
                    await coordinator.requestPoll(roomID: roomID)
                }
            }
        }
        return await coordinator.observeSubscription(roomID: rootSessionID)
    }

    /// Detaches one observer without ending coordination for the room's other
    /// consumers. Full room stop remains a session-teardown operation.
    public func detachSharedChatObservation(
        _ observation: AgentSharedChatCoordinator.Observation
    ) async {
        await sharedChatCoordinatorStorage?.detach(observation)
    }

    /// Ends coordination for one room during session teardown, terminating all
    /// its event streams. Messages that never reached a synthetic turn stay
    /// queued for a future session consumer.
    public func stopSharedChatObservation(rootSessionID: String) async {
        await sharedChatCoordinatorStorage?.stop(roomID: rootSessionID)
    }

    /// Declares consumer-side activity (running or queued prompts) for one
    /// observer, so the Core never authorises a synthetic turn concurrently
    /// with that consumer's work. Another observer reporting itself idle can
    /// never clear this declaration.
    public func setSharedChatConsumerBusy(
        _ isBusy: Bool,
        observation: AgentSharedChatCoordinator.Observation
    ) async {
        await sharedChatCoordinator().setConsumerBusy(isBusy, observation: observation)
    }

    /// Atomically tries to take a published auto-trigger for one observer. The
    /// same trigger can reach multiple observers of a room; only one `started`
    /// resolution returns ``AgentSharedChatAutoTriggerClaimResult/acquired``,
    /// and only its owner can later release it. Consumers must treat
    /// `notAcquired` as stale and must not start a generation.
    @discardableResult
    public func resolveSharedChatAutoTrigger(
        id: UUID,
        observation: AgentSharedChatCoordinator.Observation,
        resolution: AgentSharedChatAutoTriggerResolution
    ) async -> AgentSharedChatAutoTriggerClaimResult {
        await sharedChatCoordinatorStorage?.resolveAutoTrigger(
            id: id,
            observation: observation,
            resolution: resolution
        ) ?? .notAcquired
    }

    /// Returns an unclaimed trigger of a retired room to the queue. A consumer
    /// that already rebound to another session has no observation left there,
    /// but must still release the batch it will never answer.
    public func declineSharedChatAutoTrigger(
        id: UUID,
        rootSessionID: String
    ) async {
        await sharedChatCoordinatorStorage?.declineAutoTrigger(
            id: id,
            roomID: rootSessionID
        )
    }

    /// Returns the descriptors currently active for one session. This lookup is
    /// intended for best-effort replay presentation; live calls already carry
    /// the descriptor snapshot selected for their model round.
}
