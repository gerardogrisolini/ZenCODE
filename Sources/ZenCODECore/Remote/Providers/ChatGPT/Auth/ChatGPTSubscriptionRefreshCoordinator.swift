//
//  ChatGPTSubscriptionRefreshCoordinator.swift
//  ZenCODE
//
//  Shares a single in-flight ChatGPT Subscription token refresh across consumers.
//

import Foundation

/// Shares a token refresh across all consumers that still hold the same
/// refresh token. The underlying task is intentionally independent of any one
/// caller: cancelling one request must not abort an auth refresh another
/// stream is awaiting. When the final waiter leaves, the task is cancelled so
/// an abandoned refresh cannot outlive its consumers.
actor ChatGPTSubscriptionRefreshCoordinator {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<CodexAgentCredentials, Error>]
    }

    private var flights: [String: Flight] = [:]
    /// Internal observability keeps concurrent refresh tests deterministic;
    /// production construction leaves this unset.
    private let onWaiterCountChanged: (@Sendable (Int) -> Void)?

    init(
        onWaiterCountChanged: (@Sendable (Int) -> Void)? = nil
    ) {
        self.onWaiterCountChanged = onWaiterCountChanged
    }

    func refresh(
        credentials: CodexAgentCredentials,
        operation: @escaping @Sendable (CodexAgentCredentials) async throws -> CodexAgentCredentials
    ) async throws -> CodexAgentCredentials {
        try Task.checkCancellation()

        let refreshKey = credentials.refreshToken
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A cancellation can race the entry into the continuation.
                // Never install a waiter that has already been cancelled.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                addWaiter(
                    continuation,
                    id: waiterID,
                    credentials: credentials,
                    refreshKey: refreshKey,
                    operation: operation
                )
            }
        } onCancel: {
            Task(name: "ChatGPT authorization background task") {
                await self.cancelWaiter(id: waiterID, for: refreshKey)
            }
        }
    }

    private func addWaiter(
        _ continuation: CheckedContinuation<CodexAgentCredentials, Error>,
        id waiterID: UUID,
        credentials: CodexAgentCredentials,
        refreshKey: String,
        operation: @escaping @Sendable (CodexAgentCredentials) async throws -> CodexAgentCredentials
    ) {
        if var flight = flights[refreshKey] {
            flight.waiters[waiterID] = continuation
            flights[refreshKey] = flight
            onWaiterCountChanged?(flight.waiters.count)
            return
        }

        let flightID = UUID()
        let refreshTask = Task(name: "ChatGPT authorization background task") { [weak self] in
            let result: Result<CodexAgentCredentials, Error>
            do {
                result = .success(try await operation(credentials))
            } catch {
                result = .failure(error)
            }
            await self?.finish(
                id: flightID,
                for: refreshKey,
                with: result
            )
        }
        flights[refreshKey] = Flight(
            id: flightID,
            task: refreshTask,
            waiters: [waiterID: continuation]
        )
        onWaiterCountChanged?(1)
    }

    private func cancelWaiter(id waiterID: UUID, for refreshKey: String) {
        guard var flight = flights[refreshKey],
              let continuation = flight.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())

        guard flight.waiters.isEmpty else {
            flights[refreshKey] = flight
            onWaiterCountChanged?(flight.waiters.count)
            return
        }
        flights[refreshKey] = nil
        onWaiterCountChanged?(0)
        flight.task.cancel()
    }

    private func finish(
        id flightID: UUID,
        for refreshKey: String,
        with result: Result<CodexAgentCredentials, Error>
    ) {
        guard let flight = flights[refreshKey], flight.id == flightID else {
            return
        }
        flights[refreshKey] = nil
        onWaiterCountChanged?(0)
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }
}
