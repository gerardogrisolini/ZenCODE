//
//  StdioLineReaderTests.swift
//  ZenCODE
//
//  Deterministic coverage for StdioLineReader's EOF/HUP/ERR handling. Each
//  test drives a real pipe so the poll/read loop is exercised as in production
//  and a regression would hang (caught by the suite time limit) or spin instead
//  of terminating.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
@testable import ZenCODECore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioLineReaderTests {
    private static func makePipe() -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            pipe(buffer.baseAddress!)
        }
        #expect(result == 0)
        return (descriptors[0], descriptors[1])
    }

    private static func writeText(_ text: String, to descriptor: Int32) {
        // The POSIX `write` is called unqualified on purpose: qualifying it as
        // `Darwin.write` would not compile on Linux, where the symbol comes from
        // `Glibc`. The conditional imports above bring exactly one of them into
        // scope. The helpers are named `writeText*` so they cannot shadow it.
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(
                    descriptor,
                    buffer.baseAddress! + offset,
                    buffer.count - offset
                )
                guard written > 0 else {
                    return
                }
                offset += written
            }
        }
    }

    /// Writes to a non-blocking descriptor, reporting whether the whole payload
    /// went through. A refused write is not an error here: the producer simply
    /// retries once the reader has drained space.
    private static func writeTextNonBlocking(_ text: String, to descriptor: Int32) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            write(descriptor, buffer.baseAddress, buffer.count) == buffer.count
        }
    }

    @Test
    func readsCompleteLinesAndStripsCarriageReturns() throws {
        let pipe = Self.makePipe()
        defer { close(pipe.read) }
        let reader = StdioLineReader(fileDescriptor: pipe.read)

        Self.writeText("first\r\nsecond\n", to: pipe.write)
        close(pipe.write)

        #expect(reader.readLine() == "first")
        #expect(reader.readLine() == "second")
        #expect(reader.readLine() == nil)
    }

    @Test
    func eofFlushesRemainderThenReturnsNilWithoutSpinning() throws {
        let pipe = Self.makePipe()
        defer { close(pipe.read) }
        let reader = StdioLineReader(fileDescriptor: pipe.read)

        // No trailing newline: the remainder must be flushed once at EOF.
        Self.writeText("partial", to: pipe.write)
        close(pipe.write)

        #expect(reader.readLine() == "partial")
        #expect(reader.readLine() == nil)
        #expect(reader.hasReachedEndOfInput)
        // Once EOF latched, further calls return immediately instead of
        // re-polling a dead descriptor in a tight loop.
        #expect(reader.readLine() == nil)
    }

    @Test
    func writerHangUpEndsInputImmediately() throws {
        let pipe = Self.makePipe()
        defer { close(pipe.read) }
        let reader = StdioLineReader(fileDescriptor: pipe.read)

        // Closing the write end with no buffered data yields POLLHUP: the
        // reader must terminate rather than busy-loop on the ready descriptor.
        close(pipe.write)

        let started = Date()
        #expect(reader.readLine() == nil)
        #expect(reader.hasReachedEndOfInput)
        // A hang-up is reported instantly; a spin would still return nil but
        // only after burning CPU, so bound the wall time as a smoke check.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test
    func closedDescriptorIsTreatedAsEndOfInput() throws {
        let pipe = Self.makePipe()
        let reader = StdioLineReader(fileDescriptor: pipe.read)
        close(pipe.write)
        close(pipe.read)

        // POLLNVAL on an already-closed descriptor must end input instead of
        // looping forever on the immediately-returning poll.
        #expect(reader.readLine() == nil)
        #expect(reader.hasReachedEndOfInput)
    }

    @Test
    func cancelledTaskStopsReadingWithoutInput() async throws {
        let pipe = Self.makePipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }
        let reader = StdioLineReader(fileDescriptor: pipe.read)

        let task = Task.detached {
            reader.readLine()
        }
        // No data is ever written: only cooperative cancellation can end the
        // poll loop. Waiting for the loop to actually be in `poll` keeps the
        // test on the interleaving it claims to cover (cancelling a blocked
        // read) instead of degrading into the entry-guard case.
        await terminalWaitUntil { reader.pollWaitCount > 0 }
        task.cancel()

        #expect(await task.value == nil)
        #expect(!reader.hasReachedEndOfInput)
    }

    @Test
    func tokenCancellationStopsReadingOffTheCooperativePool() async throws {
        let pipe = Self.makePipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }
        let reader = StdioLineReader(fileDescriptor: pipe.read)

        // `TerminalBlockingRead` runs the read on a dedicated dispatch queue
        // where `Task.isCancelled` is always `false`, so only the token can end
        // the poll loop. The bridge waits for this body to return, so a read
        // that ignored the token would hang the awaiting side forever.
        let token = TerminalBlockingReadToken()
        let didFinish = TerminalTestFlag()

        async let line = TerminalBlockingRead.run(token: token) { token in
            defer { didFinish.set(true) }
            return reader.readLine(shouldCancel: token.isCancelled)
        }

        // No data is ever written: only the token can end the poll loop. The
        // cancellation is issued once the read is provably blocked in `poll`.
        await terminalWaitUntil { reader.pollWaitCount > 0 }
        token.cancel()

        #expect(await line == nil)
        #expect(didFinish.value)
        #expect(!reader.hasReachedEndOfInput)
    }

    @Test
    func tokenAwareReadStillReturnsAvailableLines() throws {
        let pipe = Self.makePipe()
        defer { close(pipe.read) }
        let reader = StdioLineReader(fileDescriptor: pipe.read)
        let token = TerminalBlockingReadToken()

        Self.writeText("hello\n", to: pipe.write)
        close(pipe.write)

        // An uncancelled token must not change normal read behaviour.
        #expect(reader.readLine(shouldCancel: token.isCancelled) == "hello")
    }

    @Test
    func drainBufferedLinesReturnsPendingInput() throws {
        let pipe = Self.makePipe()
        defer { close(pipe.read) }
        let reader = StdioLineReader(fileDescriptor: pipe.read)

        Self.writeText("alpha\nbeta\n", to: pipe.write)
        close(pipe.write)

        #expect(reader.drainBufferedLines(waitMilliseconds: 200) == ["alpha", "beta"])
    }

    @Test
    func drainStopsOnCancellationDespiteAContinuousProducer() async throws {
        let pipe = Self.makePipe()
        let reader = StdioLineReader(fileDescriptor: pipe.read)
        // Non-blocking write end: the producer must never wedge inside `write`
        // once the drain stops consuming, otherwise this test could not close
        // the descriptors while that thread is still parked in a syscall.
        _ = fcntl(pipe.write, F_SETFL, fcntl(pipe.write, F_GETFL, 0) | O_NONBLOCK)

        // A producer that never stops: every drain iteration finds more data
        // within its wait window, so the "input went quiet" exit is unreachable.
        // Only the token can end the loop, and because `TerminalBlockingRead`
        // resumes its caller only after the body returns, a drain that ignored
        // the token would hang the whole teardown, not just this read.
        let shouldKeepWriting = TerminalTestFlag(true)
        let producerDidExit = TerminalTestSignal()

        let producer = Thread {
            while shouldKeepWriting.value {
                if !Self.writeTextNonBlocking("paste-line\n", to: pipe.write) {
                    // Buffer full: yield instead of spinning on EAGAIN.
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            producerDidExit.signal()
        }
        producer.start()

        let token = TerminalBlockingReadToken()
        let drained = await TerminalBlockingRead.run(token: token) { token in
            reader.drainBufferedLines(
                waitMilliseconds: 80,
                shouldCancel: {
                    // Cancel from the callback executed by the drain itself.
                    // Observing `pollWaitCount` from the test task left a race:
                    // the drain could finish between that observation and
                    // `token.cancel()`, legitimately publishing its result.
                    // Here the fourth completed poll and cancellation share the
                    // blocking thread, so cancellation is guaranteed to land
                    // while the continuous-input loop is still active.
                    if reader.pollWaitCount > 3 {
                        token.cancel()
                    }
                    return token.isCancelled()
                }
            )
        }

        // Cancelled, so the bridge discards the partial paste; returning proves
        // the drain observed cancellation while input kept arriving.
        #expect(reader.pollWaitCount > 3)
        #expect(drained == nil)

        shouldKeepWriting.set(false)
        // The descriptors stay open until the producer has left its write loop.
        await producerDidExit.wait()
        close(pipe.write)
        close(pipe.read)
    }

    @Test
    func drainWithAnUncancelledTokenStillReturnsPendingInput() throws {
        let pipe = Self.makePipe()
        defer { close(pipe.read) }
        let reader = StdioLineReader(fileDescriptor: pipe.read)
        let token = TerminalBlockingReadToken()

        Self.writeText("alpha\nbeta\n", to: pipe.write)
        close(pipe.write)

        // UX unchanged: a normal paste still drains completely.
        #expect(
            reader.drainBufferedLines(
                waitMilliseconds: 200,
                shouldCancel: token.isCancelled
            ) == ["alpha", "beta"]
        )
    }

    @Test
    func acpLineStreamDeliversLinesInOrderAndFinishesAtEOF() async throws {
        let pipe = Self.makePipe()
        defer { close(pipe.read) }
        let reader = StdioLineReader(fileDescriptor: pipe.read)

        // The final request has no newline. ACP must receive it before EOF ends
        // the stream, and the stream must retain the stdin order verbatim.
        Self.writeText("first\nsecond\npartial", to: pipe.write)
        close(pipe.write)

        var lines: [String] = []
        for await line in AgentRuntimeLauncher.acpLineStream(reader: reader) {
            lines.append(line)
        }

        #expect(lines == ["first", "second", "partial"])
        #expect(reader.hasReachedEndOfInput)
    }

    @Test
    func cancellingACPReadSignalsTheDispatchBridgeToken() async throws {
        let pipe = Self.makePipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }
        let reader = StdioLineReader(fileDescriptor: pipe.read)

        let task = Task(name: "StdioLineReaderTests.ACP-cancellation") {
            await AgentRuntimeLauncher.readACPLineOffCooperativePool(reader: reader)
        }
        // Order the cancel after the real `poll` has started. This verifies the
        // dispatch bridge's token rather than the early-cancel entry guard.
        await terminalWaitUntil { reader.pollWaitCount > 0 }
        task.cancel()

        #expect(await task.value == nil)
        #expect(!reader.hasReachedEndOfInput)
    }
}
