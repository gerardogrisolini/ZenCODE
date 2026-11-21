//
//  ChatGPTSubscriptionWebSocketPool+HTTPStreams.swift
//  ZenCODE
//
//  HTTP streaming owned by the ChatGPT Subscription WebSocket pool: opening
//  and releasing HTTP streams and the per-scope HTTP fallback state.
//

import Foundation
import Synchronization

extension ChatGPTSubscriptionWebSocketPool {
    func openHTTPStream(
        _ request: RemoteHTTPStreamingRequest,
        scopeID: String
    ) async throws -> HTTPStreamLease {
        let opener = httpStreamOpener
        let pendingOwner = state.withLock {
            state -> (token: UInt64, task: Task<RemoteHTTPStreamingResponse, Error>)?
        in
            // Task construction and publication share the same critical
            // section as terminal shutdown. This prevents an unowned opener
            // from escaping after the terminal fence linearizes.
            guard !state.isTerminallyShutdown,
                  !state.closedHTTPFallbackScopeIDs.contains(scopeID) else {
                return nil
            }

            // Constructing and publishing the unstructured task is atomic
            // with respect to teardown. Its operation executes independently
            // after this short state mutation completes.
            let openingTask = Task<RemoteHTTPStreamingResponse, Error> {
                try await opener(request)
            }
            let token = state.makeToken()
            state.pendingHTTPStreams[token] = PendingHTTPStream(scopeID: scopeID, task: openingTask)
            return (token, openingTask)
        }
        guard let pendingOwner else {
            throw CancellationError()
        }
        let token = pendingOwner.token
        let openingTask = pendingOwner.task

        let response: RemoteHTTPStreamingResponse
        do {
            response = try await withTaskCancellationHandler {
                try await openingTask.value
            } onCancel: {
                openingTask.cancel()
            }
        } catch {
            _ = state.withLock {
                $0.pendingHTTPStreams.removeValue(forKey: token)
            }
            throw error
        }

        await beforeHTTPStreamRegistration()

        let didRegister = state.withLock { state -> Bool in
            // `shutdown()` and `closeHTTPFallbackScope` remove a pending token
            // before cancelling its opener. The opener may nevertheless win its
            // cancellation race and return a response. Only the still-pending
            // owner is allowed to promote that response to an active stream;
            // otherwise teardown would leak a body after it completed.
            guard state.pendingHTTPStreams.removeValue(forKey: token) != nil,
                  !state.isTerminallyShutdown,
                  !state.closedHTTPFallbackScopeIDs.contains(scopeID) else {
                return false
            }
            state.activeHTTPStreams[token] = ActiveHTTPStream(scopeID: scopeID, body: response.body)
            return true
        }
        guard didRegister else {
            response.body.cancel()
            throw CancellationError()
        }
        return HTTPStreamLease(token: token, response: response)
    }

    func releaseHTTPStream(_ lease: HTTPStreamLease) {
        _ = state.withLock {
            $0.activeHTTPStreams.removeValue(forKey: lease.token)
        }
    }

    func hasActiveHTTPStream(scopeID: String) -> Bool {
        state.withLock {
            $0.activeHTTPStreams.values.contains { $0.scopeID == scopeID }
        }
    }

    func hasPendingHTTPStream(scopeID: String) -> Bool {
        state.withLock {
            $0.pendingHTTPStreams.values.contains { $0.scopeID == scopeID }
        }
    }

    func usesHTTPFallback(scopeID: String) -> Bool {
        state.withLock {
            !$0.closedHTTPFallbackScopeIDs.contains(scopeID)
                && $0.httpFallbackScopeIDs.contains(scopeID)
        }
    }

    func isHTTPFallbackScopeClosed(scopeID: String) -> Bool {
        state.withLock { $0.closedHTTPFallbackScopeIDs.contains(scopeID) }
    }

    @discardableResult
    func activateHTTPFallback(scopeID: String) -> Bool {
        state.withLock { state in
            guard !state.closedHTTPFallbackScopeIDs.contains(scopeID) else {
                return false
            }
            return state.httpFallbackScopeIDs.insert(scopeID).inserted
        }
    }

    func closeHTTPFallbackScope(scopeID: String) {
        let retired = state.withLock { state -> (
            [Task<RemoteHTTPStreamingResponse, Error>],
            [RemoteHTTPBody]
        ) in
            state.closedHTTPFallbackScopeIDs.insert(scopeID)
            state.httpFallbackScopeIDs.remove(scopeID)
            let pendingTokens = state.pendingHTTPStreams.compactMap { token, stream in
                stream.scopeID == scopeID ? token : nil
            }
            let pendingTasks = pendingTokens.compactMap {
                state.pendingHTTPStreams.removeValue(forKey: $0)?.task
            }
            let activeTokens = state.activeHTTPStreams.compactMap { token, stream in
                stream.scopeID == scopeID ? token : nil
            }
            let bodies = activeTokens.compactMap {
                state.activeHTTPStreams.removeValue(forKey: $0)?.body
            }
            return (pendingTasks, bodies)
        }
        for task in retired.0 {
            task.cancel()
        }
        for body in retired.1 {
            body.cancel()
        }
    }
}
