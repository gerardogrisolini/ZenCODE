//
//  ChatGPTSubscriptionConcurrencyTests.swift
//  ZenCODE
//
//  Deterministic concurrency coverage for ChatGPT remote auth and WebSocket
//  dispatching. These tests do not open an OAuth or WebSocket connection.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing

@Suite("ChatGPT Subscription concurrency")
struct ChatGPTSubscriptionConcurrencyTests {
    @Test
    func chatGPTRefreshCoordinatorCoalescesConcurrentRefreshes() async throws {
        let secondWaiterRegistered = ChatGPTSubscriptionTestGate()
        let coordinator = ChatGPTSubscriptionRefreshCoordinator { waiterCount in
            guard waiterCount == 2 else {
                return
            }
            Task {
                await secondWaiterRegistered.open()
            }
        }
        let credentials = CodexAgentCredentials(
            accessToken: "expired-access-token",
            refreshToken: "rotating-refresh-token",
            expiresAt: .distantPast,
            accountID: "account"
        )
        let expected = CodexAgentCredentials(
            accessToken: "fresh-access-token",
            refreshToken: "rotated-refresh-token",
            expiresAt: .distantFuture,
            accountID: "account"
        )
        let started = ChatGPTSubscriptionTestGate()
        let release = ChatGPTSubscriptionTestGate()
        let refreshCount = Mutex(0)
        let operation: @Sendable (CodexAgentCredentials) async throws -> CodexAgentCredentials = { _ in
            refreshCount.withLock { $0 += 1 }
            await started.open()
            await release.wait()
            return expected
        }

        let first = Task {
            try await coordinator.refresh(
                credentials: credentials,
                operation: operation
            )
        }
        await started.wait()
        let second = Task {
            try await coordinator.refresh(
                credentials: credentials,
                operation: operation
            )
        }

        // Both callers have now registered against the still-blocked flight;
        // opening this gate cannot race the second registration.
        await secondWaiterRegistered.wait()
        await release.open()

        #expect(try await first.value == expected)
        #expect(try await second.value == expected)
        #expect(refreshCount.withLock { $0 } == 1)
    }

    @Test
    func chatGPTRefreshCoordinatorCancelsAbandonedWaiterImmediately() async throws {
        let coordinator = ChatGPTSubscriptionRefreshCoordinator()
        let credentials = CodexAgentCredentials(
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            expiresAt: .distantPast,
            accountID: "account"
        )
        let started = ChatGPTSubscriptionTestGate()
        let release = ChatGPTSubscriptionTestGate()
        let refreshCount = Mutex(0)
        let refresh = Task {
            try await coordinator.refresh(credentials: credentials) { _ in
                refreshCount.withLock { $0 += 1 }
                await started.open()
                await release.wait()
                try Task.checkCancellation()
                return credentials
            }
        }

        await started.wait()
        refresh.cancel()
        do {
            _ = try await refresh.value
            Issue.record("A cancelled refresh waiter unexpectedly completed.")
        } catch is CancellationError {
            // Expected: cancellation is delivered without waiting for OAuth.
        }

        #expect(refreshCount.withLock { $0 } == 1)
        await release.open()
    }

    @Test
    func chatGPTWebSocketDispatcherBackPressuresWithoutDroppingMessages() async throws {
        let source = ChatGPTSubscriptionFrameSource()
        let firstFrameDelivered = ChatGPTSubscriptionTestGate()
        let secondFrameDelivered = ChatGPTSubscriptionTestGate()
        let thirdFrameDelivered = ChatGPTSubscriptionTestGate()
        let driver = ChatGPTSubscriptionNIOWebSocketDriver(
            maximumQueuedApplicationMessages: 2,
            receiveFrame: {
                try await source.receive()
            },
            sendFrame: { _ in },
            closeConnection: { _, _ in },
            onFrameDelivered: { frame in
                guard case let .text(text, _) = frame else {
                    return
                }
                switch text {
                case "first":
                    await firstFrameDelivered.open()
                case "second":
                    await secondFrameDelivered.open()
                case "third":
                    await thirdFrameDelivered.open()
                default:
                    break
                }
            }
        )
        await driver.start()

        await source.enqueue(.text("first"))
        await firstFrameDelivered.wait()
        await source.enqueue(.text("second"))
        await secondFrameDelivered.wait()
        #expect(await driver.bufferedApplicationMessageCount == 2)

        await source.enqueue(.text("third"))
        #expect(try await driver.receive() == .text("first"))
        await thirdFrameDelivered.wait()
        #expect(await driver.bufferedApplicationMessageCount == 2)
        #expect(try await driver.receive() == .text("second"))
        #expect(try await driver.receive() == .text("third"))

        await driver.close(
            code: ChatGPTSubscriptionWebSocketCloseCode.normalClosure,
            reason: nil
        )
    }

    @Test
    func chatGPTWebSocketDispatcherProcessesPingAndDrainsBufferedTextBeforeRemoteClose() async throws {
        let source = ChatGPTSubscriptionFrameSource()
        let applicationFrameDelivered = ChatGPTSubscriptionTestGate()
        let pingFrameDelivered = ChatGPTSubscriptionTestGate()
        let closeFrameDelivered = ChatGPTSubscriptionTestGate()
        let driver = ChatGPTSubscriptionNIOWebSocketDriver(
            maximumQueuedApplicationMessages: 1,
            receiveFrame: {
                try await source.receive()
            },
            sendFrame: { _ in },
            closeConnection: { _, _ in },
            onFrameDelivered: { frame in
                switch frame {
                case let .text(text, _) where text == "buffered-before-close":
                    await applicationFrameDelivered.open()
                case .ping:
                    await pingFrameDelivered.open()
                case .close:
                    await closeFrameDelivered.open()
                default:
                    break
                }
            }
        )
        await driver.start()

        await source.enqueue(.text("buffered-before-close"))
        await applicationFrameDelivered.wait()
        #expect(await driver.bufferedApplicationMessageCount == 1)

        // A full application queue cannot delay handling the remote ping or
        // close. The close is nevertheless reported after the queued text.
        await source.enqueue(.ping(Data("remote-ping".utf8)))
        await pingFrameDelivered.wait()
        await source.enqueue(
            .close(code: ChatGPTSubscriptionWebSocketCloseCode.normalClosure)
        )
        await closeFrameDelivered.wait()
        #expect(await driver.bufferedApplicationMessageCount == 1)
        #expect(try await driver.receive() == .text("buffered-before-close"))

        do {
            _ = try await driver.receive()
            Issue.record("A remotely closed dispatcher unexpectedly returned a frame.")
        } catch let error as RemoteTransportError {
            #expect(error == .closed)
        }
    }

    @Test
    func chatGPTWebSocketDispatcherCompletesPingWithFullApplicationQueue() async throws {
        let source = ChatGPTSubscriptionFrameSource()
        let applicationFrameDelivered = ChatGPTSubscriptionTestGate()
        let pongFrameDelivered = ChatGPTSubscriptionTestGate()
        let driver = ChatGPTSubscriptionNIOWebSocketDriver(
            maximumQueuedApplicationMessages: 1,
            receiveFrame: {
                try await source.receive()
            },
            sendFrame: { frame in
                guard case let .ping(payload) = frame else {
                    throw RemoteTransportError.protocolViolation(
                        "Expected the driver to send a ping frame"
                    )
                }
                await source.enqueue(.pong(payload))
            },
            closeConnection: { _, _ in },
            onFrameDelivered: { frame in
                switch frame {
                case let .text(text, _) where text == "buffered-before-pong":
                    await applicationFrameDelivered.open()
                case .pong:
                    await pongFrameDelivered.open()
                default:
                    break
                }
            }
        )
        await driver.start()
        await source.enqueue(.text("buffered-before-pong"))
        await applicationFrameDelivered.wait()
        #expect(await driver.bufferedApplicationMessageCount == 1)

        let ping = Task {
            try await driver.sendPing()
        }
        await pongFrameDelivered.wait()
        try await ping.value
        #expect(await driver.bufferedApplicationMessageCount == 1)

        await driver.close(
            code: ChatGPTSubscriptionWebSocketCloseCode.normalClosure,
            reason: nil
        )
    }

    @Test
    func chatGPTWebSocketDispatcherDrainsBufferedTextBeforeRemoteError() async throws {
        let source = ChatGPTSubscriptionFrameSource()
        let applicationFrameDelivered = ChatGPTSubscriptionTestGate()
        let driver = ChatGPTSubscriptionNIOWebSocketDriver(
            maximumQueuedApplicationMessages: 1,
            receiveFrame: {
                try await source.receive()
            },
            sendFrame: { _ in },
            closeConnection: { _, _ in },
            onFrameDelivered: { frame in
                guard case let .text(text, _) = frame,
                      text == "buffered-before-error" else {
                    return
                }
                await applicationFrameDelivered.open()
            }
        )
        await driver.start()
        await source.enqueue(.text("buffered-before-error"))
        await applicationFrameDelivered.wait()
        #expect(await driver.bufferedApplicationMessageCount == 1)

        await source.fail(RemoteTransportError.closed)
        #expect(try await driver.receive() == .text("buffered-before-error"))
        do {
            _ = try await driver.receive()
            Issue.record("A remotely failed dispatcher unexpectedly returned a frame.")
        } catch let error as RemoteTransportError {
            #expect(error == .closed)
        }
    }

    @Test
    func chatGPTWebSocketDispatcherTeardownClearsBufferAndStopsReader() async throws {
        let source = ChatGPTSubscriptionFrameSource()
        let applicationFrameDelivered = ChatGPTSubscriptionTestGate()
        let connectionClosed = ChatGPTSubscriptionTestGate()
        let driver = ChatGPTSubscriptionNIOWebSocketDriver(
            maximumQueuedApplicationMessages: 1,
            receiveFrame: {
                try await source.receive()
            },
            sendFrame: { _ in },
            closeConnection: { _, _ in
                await connectionClosed.open()
            },
            onFrameDelivered: { frame in
                guard case let .text(text, _) = frame,
                      text == "buffered" else {
                    return
                }
                await applicationFrameDelivered.open()
            }
        )
        await driver.start()
        await source.enqueue(.text("buffered"))
        await applicationFrameDelivered.wait()
        #expect(await driver.bufferedApplicationMessageCount == 1)

        await driver.close(
            code: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
            reason: nil
        )

        await connectionClosed.wait()
        #expect(await driver.bufferedApplicationMessageCount == 0)
        do {
            _ = try await driver.receive()
            Issue.record("A closed dispatcher unexpectedly returned a frame.")
        } catch let error as RemoteTransportError {
            #expect(error == .closed)
        }
    }
}

private actor ChatGPTSubscriptionTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private actor ChatGPTSubscriptionFrameSource {
    private var queuedFrames: [RemoteWebSocketFrame] = []
    private var receiveWaiter: CheckedContinuation<RemoteWebSocketFrame?, Error>?
    private var terminalError: Error?

    func enqueue(_ frame: RemoteWebSocketFrame) {
        queuedFrames.append(frame)
        resumeReceiveWaiterIfPossible()
    }

    func fail(_ error: Error) {
        guard terminalError == nil else {
            return
        }
        terminalError = error
        let receiveWaiter = self.receiveWaiter
        self.receiveWaiter = nil
        receiveWaiter?.resume(throwing: error)
    }

    func receive() async throws -> RemoteWebSocketFrame? {
        if !queuedFrames.isEmpty {
            return queuedFrames.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }
        return try await withCheckedThrowingContinuation { continuation in
            if !queuedFrames.isEmpty {
                continuation.resume(returning: queuedFrames.removeFirst())
            } else if let terminalError {
                continuation.resume(throwing: terminalError)
            } else {
                precondition(receiveWaiter == nil)
                receiveWaiter = continuation
            }
        }
    }

    private func resumeReceiveWaiterIfPossible() {
        guard !queuedFrames.isEmpty,
              let receiveWaiter else {
            return
        }
        self.receiveWaiter = nil
        receiveWaiter.resume(returning: queuedFrames.removeFirst())
    }

}
