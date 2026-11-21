//
//  ChatPendingRequestHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation

/// An interaction host that publishes each request in the snapshot of a
/// ``ChatSessionStateReducer`` (``ChatSessionSnapshot/pendingRequests``) and
/// waits until the client answers it.
///
/// The client renders the pending requests from the snapshot and answers each
/// one with ``resolve(_:answer:)``; anyone holding the host can resolve a
/// request, whichever view presented it. A `nil` answer is a refusal, as for
/// every ``ChatInteractionHost``. Cancelling the task that waits on a request
/// refuses it too, and ``cancelPendingRequests()`` refuses every open one.
/// Each request resumes exactly once, then leaves the snapshot.
///
/// The controller asks for menus, text, and attachments only when the matching
/// capability is declared, so the client declares in `capabilities` what it
/// renders. Workspace access has no capability: the controller asks for it
/// whenever the selected tools need the folder, so the host publishes it only
/// when the client gates folder access (`gatesWorkspaceAccess`), and grants
/// it at once otherwise, like the protocol's default.
@ChatSessionActor
public final class ChatPendingRequestHost: ChatInteractionHost {
    public nonisolated let capabilities: ChatChannelCapabilities
    /// The reducer whose snapshot publishes the requests.
    public let reducer: ChatSessionStateReducer
    /// `true` when workspace access is published and waits for the client;
    /// `false` when it is granted without asking.
    public nonisolated let gatesWorkspaceAccess: Bool
    private let openExternalHandler: (@Sendable (ChatOpenTarget) async throws -> Void)?
    private var pending: [UUID: PendingRequest] = [:]

    private struct PendingRequest {
        let kind: ChatPendingRequest.Kind
        let continuation: CheckedContinuation<ChatPendingRequest.Answer?, Never>
    }

    /// `openExternal` opens a file or URL for
    /// ``ChatInteractionHost/openExternal(_:)``; without it the host cannot
    /// open anything and throws, like the protocol's default.
    public nonisolated init(
        reducer: ChatSessionStateReducer,
        capabilities: ChatChannelCapabilities,
        gatesWorkspaceAccess: Bool = false,
        openExternal: (@Sendable (ChatOpenTarget) async throws -> Void)? = nil
    ) {
        self.reducer = reducer
        self.capabilities = capabilities
        self.gatesWorkspaceAccess = gatesWorkspaceAccess
        self.openExternalHandler = openExternal
    }

    // MARK: - Answers

    /// Answers the request `id` and resumes the call waiting on it. Returns
    /// `false`, changing nothing, when no such request is open or when
    /// `answer` does not answer its kind (see ``ChatPendingRequest/Answer``).
    @discardableResult
    public func resolve(_ id: UUID, answer: ChatPendingRequest.Answer?) -> Bool {
        guard let request = pending[id] else { return false }
        if let answer, !request.kind.accepts(answer) {
            return false
        }
        pending[id] = nil
        reducer.removePendingRequest(id: id)
        request.continuation.resume(returning: answer)
        return true
    }

    /// Refuses every open request, oldest first, for a client that goes away.
    public func cancelPendingRequests() {
        for request in reducer.snapshot.pendingRequests {
            resolve(request.id, answer: nil)
        }
        // The snapshot lists every open request of this host, as both change
        // together; this pass refuses one it would miss all the same.
        for id in Array(pending.keys) {
            resolve(id, answer: nil)
        }
    }

    // MARK: - ChatInteractionHost

    public func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        guard case let .consent(decision)? = await ask(.toolConsent(request)) else { return nil }
        return decision
    }

    public func chooseOne(
        title: String,
        items: [ChatChoiceItem],
        selectedID: String?
    ) async -> String? {
        guard case let .choice(id)? = await ask(
            .chooseOne(title: title, items: items, selectedID: selectedID)
        ) else { return nil }
        return id
    }

    public func chooseMany(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>
    ) async -> Set<String>? {
        guard case let .choices(ids)? = await ask(
            .chooseMany(title: title, items: items, selectedIDs: selectedIDs)
        ) else { return nil }
        return ids
    }

    public func chooseManyWithFocus(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>,
        focusedID: String?,
        toggleLabel: String,
        confirmLabel: String
    ) async -> ChatFocusedChoice? {
        guard case let .focusedChoice(choice)? = await ask(
            .chooseManyWithFocus(
                title: title,
                items: items,
                selectedIDs: selectedIDs,
                focusedID: focusedID,
                toggleLabel: toggleLabel,
                confirmLabel: confirmLabel
            )
        ) else { return nil }
        return choice
    }

    public func readLine(prompt: String) async -> String? {
        guard case let .text(line)? = await ask(.readLine(prompt: prompt)) else { return nil }
        return line
    }

    public func requestWorkspaceAccess(_ request: ChatWorkspaceAccessRequest) async -> Bool {
        guard gatesWorkspaceAccess else { return true }
        guard case let .workspaceAccess(granted)? = await ask(.workspaceAccess(request)) else {
            return false
        }
        return granted
    }

    public func openExternal(_ target: ChatOpenTarget) async throws {
        guard let openExternalHandler else {
            throw ChatOpenExternalUnsupportedError()
        }
        try await openExternalHandler(target)
    }

    public func pickAttachment(startingAt directory: URL) async -> URL? {
        guard case let .attachment(url)? = await ask(.pickAttachment(startingAt: directory)) else {
            return nil
        }
        return url
    }

    // MARK: - Waiting

    /// Publishes a request of `kind` and waits for its answer: `nil` when the
    /// client refuses it or the waiting task is cancelled.
    private func ask(_ kind: ChatPendingRequest.Kind) async -> ChatPendingRequest.Answer? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Already cancelled: refuse without publishing. The handler's
                // resolve below then finds nothing to resume.
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                pending[id] = PendingRequest(kind: kind, continuation: continuation)
                reducer.addPendingRequest(ChatPendingRequest(id: id, kind: kind))
            }
        } onCancel: {
            Task { @ChatSessionActor in
                self.resolve(id, answer: nil)
            }
        }
    }
}
