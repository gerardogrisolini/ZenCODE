//
//  TerminalBlockingReadTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Covers the bridge that carries blocking terminal reads into Swift
/// concurrency without occupying an actor or a cooperative worker.
///
/// Every test here orders itself against the blocking body with `TerminalTestSignal`
/// rather than with a sleep: the interleaving under test (cancel *after* the
/// read has taken the terminal) is only reached when the ordering is enforced,
/// and a timing-based test would quietly stop covering it on a loaded machine.
@Suite(.timeLimit(.minutes(1)))
struct TerminalBlockingReadTests {
    /// Blocks until the token is cancelled, reporting entry through `didStart`.
    /// Models a POSIX read: it unwinds only on cancellation.
    private static func blockUntilCancelled(
        _ token: TerminalBlockingReadToken,
        didStart: TerminalTestSignal
    ) {
        didStart.signal()
        while !token.isCancelled() {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    @Test
    func returnsTheBlockingResultWhenNotCancelled() async {
        let value = await TerminalBlockingRead.run { _ in
            "answer"
        }
        #expect(value == "answer")
    }

    @Test
    func cancellationDoesNotCompleteUntilTheBlockingBodyHasReleasedTheTerminal() async {
        let didStart = TerminalTestSignal()
        // Models the worker's grip on the TTY: `true` for exactly as long as the
        // blocking body is inside its read and still owns raw mode.
        let isHoldingTerminal = TerminalTestFlag()

        let task = Task { () -> String? in
            await TerminalBlockingRead.run { token in
                isHoldingTerminal.set(true)
                Self.blockUntilCancelled(token, didStart: didStart)
                // Emulates the unwind cost of restoring termios: the awaiting
                // side must not be released before this completes.
                Thread.sleep(forTimeInterval: 0.05)
                isHoldingTerminal.set(false)
                return nil
            }
        }

        // Cancel only once the body owns the terminal, so the test exercises the
        // quiescence handshake rather than the entry guard.
        await didStart.wait()
        task.cancel()

        #expect(await task.value == nil)
        // The contract under test: returning from the await proves the worker
        // has left the read. Resuming on cancellation alone would observe
        // `true` here, meaning the caller could restore termios and start a
        // second reader while the first still owned the terminal.
        #expect(!isHoldingTerminal.value)
    }

    @Test
    func aCancelledReadCannotStealInputFromItsSuccessor() async {
        // Exactly one reader may own the terminal at a time. If a cancelled read
        // resumed its caller before unwinding, the successor would start while
        // the predecessor was still in `poll`/`read` and could consume its key.
        let activeReaders = Mutex(0)
        let sawOverlap = TerminalTestFlag()
        let didStart = TerminalTestSignal()

        let claimTerminal: @Sendable () -> Void = {
            activeReaders.withLock { count in
                count += 1
                if count > 1 {
                    sawOverlap.set(true)
                }
            }
        }

        let first = Task { () -> String? in
            await TerminalBlockingRead.run { token in
                claimTerminal()
                Self.blockUntilCancelled(token, didStart: didStart)
                Thread.sleep(forTimeInterval: 0.05)
                activeReaders.withLock { $0 -= 1 }
                return nil
            }
        }

        await didStart.wait()
        first.cancel()
        #expect(await first.value == nil)

        // The teardown is complete, so a fresh reader may take the terminal.
        let second = await TerminalBlockingRead.run { _ in
            claimTerminal()
            defer { activeReaders.withLock { $0 -= 1 } }
            return "answer"
        }

        #expect(second == "answer")
        #expect(!sawOverlap.value)
        #expect(activeReaders.withLock { $0 } == 0)
    }

    @Test
    func externalTokenCancellationWaitsForTheReadToRelinquishTheTerminal() async {
        // The panel stop path cancels the token directly rather than the task,
        // and must get the same quiescence guarantee.
        let token = TerminalBlockingReadToken()
        let didStart = TerminalTestSignal()
        let isHoldingTerminal = TerminalTestFlag()

        async let result = TerminalBlockingRead.run(token: token) { token in
            isHoldingTerminal.set(true)
            Self.blockUntilCancelled(token, didStart: didStart)
            Thread.sleep(forTimeInterval: 0.05)
            isHoldingTerminal.set(false)
            return "unused"
        }

        await didStart.wait()
        token.cancel()

        #expect(await result == nil)
        #expect(!isHoldingTerminal.value)
    }

    @Test
    func aLateBlockingResultAfterCancellationIsDiscarded() async {
        let didStart = TerminalTestSignal()
        let observedCancellation = TerminalTestFlag()

        let task = Task { () -> String? in
            await TerminalBlockingRead.run { token in
                Self.blockUntilCancelled(token, didStart: didStart)
                observedCancellation.set(true)
                // A key that landed during teardown must not take effect.
                return "late"
            }
        }

        await didStart.wait()
        task.cancel()
        #expect(await task.value == nil)
        // The body ran to completion before the await returned, so its
        // cancellation observation is already visible without further waiting.
        #expect(observedCancellation.value)
    }

    @Test
    func cancellingBeforeTheOutcomeIsDecidedDiscardsTheKey() {
        // Unit-level linearization point. `resolve` is the single step in which
        // a finished body's value becomes observable, and it is taken under the
        // same lock as `cancel()`. A cancellation ordered before it therefore
        // cannot be overtaken by the key the body already had in hand.
        let token = TerminalBlockingReadToken()
        token.cancel()

        #expect(token.resolve("key-pressed-during-teardown") == nil)
        #expect(token.isResolved)
    }

    @Test
    func cancellingAfterTheOutcomeIsDecidedDoesNotRewriteIt() {
        // The mirror case: a read that completed before any cancellation still
        // delivers its line, so a normal submission is never silently dropped.
        let token = TerminalBlockingReadToken()

        #expect(token.resolve("submitted") == "submitted")
        token.cancel()
        #expect(token.isResolved)
    }

    @Test
    func aCancellationObservedBeforeTheOutcomeSuppressesTheResult() async {
        // Deterministic half of the race above: the cancellation provably
        // precedes the body's return, so the read must publish nothing even
        // though the body produced a value.
        let token = TerminalBlockingReadToken()
        let didStart = TerminalTestSignal()
        let didCancel = TerminalTestSignal()

        async let result = TerminalBlockingRead.run(token: token) { _ in
            didStart.signal()
            // Blocks until the test has cancelled, so the outcome is decided
            // strictly after the cancellation.
            while !didCancel.isSignalled {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return "key-pressed-during-teardown"
        }

        await didStart.wait()
        token.cancel()
        didCancel.signal()

        #expect(await result == nil)
    }

    @Test
    func alreadyCancelledTaskNeverStartsTheBlockingBody() async {
        let didRunBody = TerminalTestFlag()
        let mayProceed = TerminalTestSignal()

        let task = Task { () -> String? in
            // The bridge must not start once the cancel has landed, so the task
            // waits for it instead of racing it with a sleep.
            await mayProceed.wait()
            return await TerminalBlockingRead.run { _ in
                didRunBody.set(true)
                return "value"
            }
        }
        task.cancel()
        mayProceed.signal()

        #expect(await task.value == nil)
        #expect(!didRunBody.value)
    }

    @Test
    func externalTokenCancellationUnblocksTheRead() async {
        let token = TerminalBlockingReadToken()
        let didStart = TerminalTestSignal()

        async let result = TerminalBlockingRead.run(token: token) { token in
            Self.blockUntilCancelled(token, didStart: didStart)
            return "unused"
        }

        await didStart.wait()
        // The panel stop path cancels the token directly, not the task.
        token.cancel()

        #expect(await result == nil)
    }

    @Test
    func aCancellationRacingTheDispatchStillUnwindsTheBody() async {
        // The token may be cancelled between the entry guard and the moment the
        // body starts running. The body must still observe it and return, or the
        // awaiting side would never be resumed.
        let token = TerminalBlockingReadToken()
        let didFinishBody = TerminalTestFlag()

        async let result = TerminalBlockingRead.run(token: token) { token in
            while !token.isCancelled() {
                Thread.sleep(forTimeInterval: 0.005)
            }
            didFinishBody.set(true)
            return "unused"
        }
        // Cancel without waiting for the body to report that it started.
        token.cancel()

        #expect(await result == nil)
        #expect(didFinishBody.value)
    }

    /// Sendable counter shared with blocking bodies running off the
    /// cooperative pool. `Mutex` is noncopyable, so it is wrapped in a class
    /// reference that can be captured by several tasks.
    private final class Counter: Sendable {
        private let value = Mutex(0)

        /// Increments and reports the new total, so a caller can detect the
        /// exact moment the last expected participant arrived.
        @discardableResult
        func increment() -> Int {
            value.withLock { value in
                value += 1
                return value
            }
        }

        var current: Int {
            value.withLock { $0 }
        }
    }

    /// Starts one blocking read gated on `token`, signalling `allReadersStarted`
    /// once `expectedReaders` of them are inside their blocking section.
    private func startBlockingReader(
        token: TerminalBlockingReadToken,
        startedReaders: Counter,
        expectedReaders: Int,
        allReadersStarted: TerminalTestSignal
    ) -> Task<Bool?, Never> {
        Task {
            await TerminalBlockingRead.run(token: token) { token in
                if startedReaders.increment() == expectedReaders {
                    allReadersStarted.signal()
                }
                while !token.isCancelled() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return true
            }
        }
    }

    @Test
    func blockingReadsDoNotStarveConcurrentAsyncWork() async {
        // The whole point of the bridge: several blocking reads in flight must
        // not prevent other tasks from making progress on the cooperative pool.
        let token = TerminalBlockingReadToken()
        let readerCount = 8
        let startedReaders = Counter()
        let allReadersStarted = TerminalTestSignal()

        var readers: [Task<Bool?, Never>] = []
        for _ in 0..<readerCount {
            readers.append(
                startBlockingReader(
                    token: token,
                    startedReaders: startedReaders,
                    expectedReaders: readerCount,
                    allReadersStarted: allReadersStarted
                )
            )
        }

        // Every reader is provably blocked before the cooperative work runs.
        await allReadersStarted.wait()
        #expect(startedReaders.current == readerCount)

        // Unrelated cooperative work still completes while reads are blocked.
        let cooperative = Task { 21 * 2 }
        #expect(await cooperative.value == 42)

        token.cancel()
        for reader in readers {
            #expect(await reader.value == nil)
        }
    }
}
