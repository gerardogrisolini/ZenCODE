//
//  ChatSlotInteractionHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/11/26.
//

import Foundation
import Synchronization

/// The interaction host of every controller a slot runs: it forwards each
/// request to the host of the channel that drives the slot now, the
/// channel's own host (or the ``ChatPendingRequestHost`` of the incarnation)
/// or the slot's ``TelegramChannel``, and moves the requests still open when
/// the channel changes.
///
/// A request is asked on the active host in a task of its own. When the slot
/// switches channel while requests wait, the host cancels those tasks, so
/// the old host sees a cancellation (a ``ChatPendingRequestHost`` refuses the
/// request, the Telegram permission broker withdraws it), and asks each
/// request again on the new host; the controller's call, which never
/// returned, receives the new host's answer. A request whose own task is
/// cancelled (the turn was stopped) is not asked again.
///
/// The active host and the open requests are kept under a lock, because
/// ``capabilities`` and the requests are read outside ``ChatSessionActor``;
/// the slot updates the active host as it switches channel or incarnation.
final class ChatSlotInteractionHost: ChatInteractionHost, Sendable {
    private struct OpenRequest {
        let task: Task<Void, Never>
        let generation: Int
        var movedToAnotherHost = false
    }

    private struct State {
        var activeHost: any ChatInteractionHost
        /// Advanced at every change of the active host.
        var generation = 0
        var openRequests: [UUID: OpenRequest] = [:]
    }

    private let state: Mutex<State>

    init(activeHost: any ChatInteractionHost) {
        state = Mutex(State(activeHost: activeHost))
    }

    /// The host that answers from now on. The requests still open on the
    /// previous host are cancelled there and asked again on `host`.
    func setActiveHost(_ host: any ChatInteractionHost) {
        let moved = state.withLock { state -> [Task<Void, Never>] in
            state.activeHost = host
            state.generation += 1
            var tasks: [Task<Void, Never>] = []
            for id in state.openRequests.keys {
                state.openRequests[id]?.movedToAnotherHost = true
                if let task = state.openRequests[id]?.task {
                    tasks.append(task)
                }
            }
            return tasks
        }
        for task in moved {
            task.cancel()
        }
    }

    /// The number of requests waiting for an answer, for tests.
    var openRequestCount: Int {
        state.withLock { $0.openRequests.count }
    }

    var capabilities: ChatChannelCapabilities {
        state.withLock { $0.activeHost.capabilities }
    }

    // MARK: - Asking

    /// Asks `body` of the active host, again on the new host when the channel
    /// changes while it waits, until a host answers or the caller's task is
    /// cancelled.
    private func ask<Answer: Sendable>(
        _ body: @escaping @Sendable (any ChatInteractionHost) async -> Answer
    ) async -> Answer? {
        while !Task.isCancelled {
            let (host, generation) = state.withLock { ($0.activeHost, $0.generation) }
            let box = AnswerBox<Answer>()
            let task = Task {
                let answer = await body(host)
                box.set(answer)
            }
            let id = UUID()
            let isCurrent = state.withLock { state -> Bool in
                guard state.generation == generation else { return false }
                state.openRequests[id] = OpenRequest(task: task, generation: generation)
                return true
            }
            guard isCurrent else {
                // The channel changed between the read and the registration:
                // this host is already stale.
                task.cancel()
                continue
            }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            let moved = state.withLock { state -> Bool in
                state.openRequests.removeValue(forKey: id)?.movedToAnotherHost ?? false
            }
            if moved, !Task.isCancelled {
                continue
            }
            return box.take()
        }
        return nil
    }

    /// Carries the answer of a request task out of it.
    private final class AnswerBox<Answer: Sendable>: Sendable {
        private let storage = Mutex<Answer?>(nil)

        func set(_ answer: Answer) {
            storage.withLock { $0 = answer }
        }

        func take() -> Answer? {
            storage.withLock { $0 }
        }
    }

    // MARK: - ChatInteractionHost

    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        await ask { await $0.requestToolConsent(request) } ?? nil
    }

    func chooseOne(
        title: String,
        items: [ChatChoiceItem],
        selectedID: String?
    ) async -> String? {
        await ask { await $0.chooseOne(title: title, items: items, selectedID: selectedID) } ?? nil
    }

    func chooseMany(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>
    ) async -> Set<String>? {
        await ask { await $0.chooseMany(title: title, items: items, selectedIDs: selectedIDs) } ?? nil
    }

    func chooseManyWithFocus(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>,
        focusedID: String?,
        toggleLabel: String,
        confirmLabel: String
    ) async -> ChatFocusedChoice? {
        await ask {
            await $0.chooseManyWithFocus(
                title: title,
                items: items,
                selectedIDs: selectedIDs,
                focusedID: focusedID,
                toggleLabel: toggleLabel,
                confirmLabel: confirmLabel
            )
        } ?? nil
    }

    func readLine(prompt: String) async -> String? {
        await ask { await $0.readLine(prompt: prompt) } ?? nil
    }

    func requestWorkspaceAccess(_ request: ChatWorkspaceAccessRequest) async -> Bool {
        await ask { await $0.requestWorkspaceAccess(request) } ?? false
    }

    func openExternal(_ target: ChatOpenTarget) async throws {
        let host = state.withLock { $0.activeHost }
        try await host.openExternal(target)
    }

    func pickAttachment(startingAt directory: URL) async -> URL? {
        await ask { await $0.pickAttachment(startingAt: directory) } ?? nil
    }
}

/// The host of a slot between incarnations, when the slot asks with pending
/// requests and no incarnation exists yet: it can do nothing and refuses
/// every request.
struct ChatRefusingInteractionHost: ChatInteractionHost {
    var capabilities: ChatChannelCapabilities { [] }

    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        nil
    }
}
