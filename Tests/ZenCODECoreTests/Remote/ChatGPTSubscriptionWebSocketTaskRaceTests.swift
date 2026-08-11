//
//  ChatGPTSubscriptionWebSocketTaskRaceTests.swift
//  ZenCODE
//
//  Focused lifecycle synchronization coverage for the WebSocket task.
//

import Foundation
import Dispatch
import Synchronization
@testable import ZenCODECore
import Testing

@Suite("ChatGPT WebSocket task lifecycle")
struct ChatGPTSubscriptionWebSocketTaskRaceTests {
    @Test
    func cancelDuringPreAdoptionWindowCancelsNewConnectionTask() async {
        let probe = ChatGPTSubscriptionWebSocketTaskCancellationProbe()
        let (adoptionReachedStream, adoptionReachedContinuation) =
            AsyncStream<Void>.makeStream()
        let continueAdoption = DispatchSemaphore(value: 0)
        let task = ChatGPTSubscriptionNIOWebSocketTask(
            connector: {
                await probe.waitForCancellationCheck()
                do {
                    try Task.checkCancellation()
                } catch {
                    await probe.connectorWasCancelled()
                    throw error
                }
                fatalError("A task adopted after cancellation must be cancelled")
            },
            beforeTaskAdoption: {
                adoptionReachedContinuation.yield()
                // The hook runs outside the lifecycle mutex. Hold exactly the
                // former publication window until cancellation wins it.
                _ = continueAdoption.wait()
            }
        )

        let resumer = Task.detached {
            task.resume()
        }
        var adoptionEvents = adoptionReachedStream.makeAsyncIterator()
        #expect(await adoptionEvents.next() != nil)
        task.cancel(with: nil, reason: nil)
        continueAdoption.signal()
        await resumer.value
        await probe.allowCancellationCheck()

        // This gate is resumed only after the connector observes the winning
        // pre-adoption cancellation; no scheduler turn is used as evidence.
        #expect(await probe.waitForConnectorCancellation())
        #expect(await probe.wasCancelled)
        #expect(task.state == .canceling)
    }

    @Test
    func terminalCancellationConsumesConnectedDriverAndClosesItOnce() async {
        let closeCodes = Mutex<[UInt16?]>([])
        let driver = ChatGPTSubscriptionNIOWebSocketDriver(
            maximumQueuedApplicationMessages: 1,
            receiveFrame: {
                throw RemoteTransportError.closed
            },
            sendFrame: { _ in },
            closeConnection: { _, _ in }
        )
        let task = ChatGPTSubscriptionNIOWebSocketTask(
            driverFactory: { driver },
            closeDriver: { driver, closeCode, reason in
                closeCodes.withLock { $0.append(closeCode) }
                Task(name: "ChatGPT WebSocket cancellation test close") {
                    await driver.close(code: closeCode, reason: reason)
                }
            }
        )

        task.resume()
        do {
            _ = try await task.receive()
            Issue.record("A driver failure unexpectedly produced a message.")
        } catch {
            // The failed receive transitions the task to terminal `.completed`.
        }
        #expect(task.state == .completed)

        task.cancel(
            with: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
            reason: nil
        )
        task.cancel(
            with: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
            reason: nil
        )

        #expect(closeCodes.withLock { $0 } == [
            ChatGPTSubscriptionWebSocketCloseCode.goingAway
        ])
    }

    @Test
    func resumeAndCancelCancelThePublishedConnectionTask() async {
        let probe = ChatGPTSubscriptionWebSocketTaskCancellationProbe()
        let task = ChatGPTSubscriptionNIOWebSocketTask(connector: {
            await probe.connectorDidStart()
            await probe.waitForCancellationCheck()
            do {
                try Task.checkCancellation()
            } catch {
                await probe.connectorWasCancelled()
                throw error
            }
            fatalError("A cancelled WebSocket connector must not remain running")
        })

        task.resume()
        await probe.waitForConnectorStart()
        task.cancel(with: nil, reason: nil)
        await probe.allowCancellationCheck()

        // The connector itself acknowledges cancellation before the assertion.
        #expect(await probe.waitForConnectorCancellation())
        #expect(await probe.wasCancelled)
        #expect(task.state == .canceling)
    }
}

private actor ChatGPTSubscriptionWebSocketTaskCancellationProbe {
    private var hasStarted = false
    private var cancellationCheckAllowed = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var checkWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Bool, Never>] = []

    var wasCancelled: Bool {
        cancelled
    }

    func connectorDidStart() {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForConnectorStart() async {
        guard !hasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func allowCancellationCheck() {
        cancellationCheckAllowed = true
        let waiters = checkWaiters
        checkWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForCancellationCheck() async {
        guard !cancellationCheckAllowed else {
            return
        }
        await withCheckedContinuation { continuation in
            checkWaiters.append(continuation)
        }
    }

    func connectorWasCancelled() {
        cancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }

    func waitForConnectorCancellation() async -> Bool {
        guard !cancelled else {
            return true
        }
        return await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }
}
