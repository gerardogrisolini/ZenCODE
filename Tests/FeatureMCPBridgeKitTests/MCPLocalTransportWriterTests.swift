//
//  MCPLocalTransportWriterTests.swift
//  ZenCODE
//

@testable import FeatureMCPBridgeKit
import Dispatch
import Foundation
import Testing

#if os(macOS)
import Darwin

/// Coverage for the local bridge's serialized stdin writer and for the local
/// request cancellation path. The tests drive real pipes so the non-blocking
/// back-pressure and teardown ordering are exercised as in production.
@Suite(.timeLimit(.minutes(1)))
struct MCPLocalTransportWriterTests {
    private static func makeNonBlockingPipe() -> Pipe {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        return pipe
    }

    @Test
    func writesAreNewlineFramedAndSerialized() async throws {
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )

        try await writer.enqueue(Data(#"{"id":1}"#.utf8))
        try await writer.enqueue(Data(#"{"id":2}"#.utf8))

        writer.finish()
        await writer.join()
        pipe.fileHandleForWriting.closeFile()

        let written = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: written, as: UTF8.self) == "{\"id\":1}\n{\"id\":2}\n")
    }

    @Test
    func bufferedJobsAreFailedBeforeTheWriterFinishesTeardown() async throws {
        // A tiny reader-side backlog makes the pipe fill up, so the jobs queued
        // behind the first one are still buffered when teardown starts.
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )

        // Fill the OS pipe buffer so the in-flight write cannot drain. Nothing
        // ever reads this pipe, which models the wedged peer exactly.
        let bulk = Data(String(repeating: "x", count: 512 * 1024).utf8)
        let blockedJob = Task { try await writer.enqueue(bulk) }
        try await Self.waitUntilWedged(writer)

        let queuedJobs = (0..<5).map { index in
            Task { try await writer.enqueue(Data("{\"id\":\(index)}".utf8)) }
        }
        try await Self.waitUntilQueuedCount(writer, atLeast: queuedJobs.count)

        // Teardown as performed by disconnect().
        writer.finish()
        writer.cancel()
        await writer.join()

        // join() returning must mean every buffered job was concluded: none of
        // these awaits may hang, which is exactly what makes closing the FD safe.
        var concluded = 0
        for job in queuedJobs {
            do {
                try await job.value
            } catch {
                // Failure is the expected outcome during teardown.
            }
            concluded += 1
        }
        do { try await blockedJob.value } catch { /* expected */ }

        #expect(concluded == queuedJobs.count)
        pipe.fileHandleForWriting.closeFile()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
    }

    @Test
    func cancelWithoutFinishStillConcludesBufferedJobs() async throws {
        // Regression: the buffered jobs' continuations must not be owned by the
        // AsyncStream. A cancelled `for await` drops buffered elements without
        // delivering them, so continuations stored inside the stream's elements
        // would never be resumed and their callers would hang forever.
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )

        // Wedge the writer on a full pipe so later jobs stay buffered.
        let bulk = Data(String(repeating: "x", count: 512 * 1024).utf8)
        let blockedJob = Task { try await writer.enqueue(bulk) }
        try await Self.waitUntilWedged(writer)

        let queuedJobs = (0..<5).map { index in
            Task { try await writer.enqueue(Data("{\"id\":\(index)}".utf8)) }
        }
        try await Self.waitUntilQueuedCount(writer, atLeast: queuedJobs.count)

        // Cancel WITHOUT finish(): the stream is never terminated, so nothing
        // but the registry sweep can conclude the buffered jobs.
        writer.cancel()
        await writer.join()

        for job in queuedJobs {
            do { try await job.value } catch { /* expected during teardown */ }
        }
        do { try await blockedJob.value } catch { /* expected */ }

        pipe.fileHandleForWriting.closeFile()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
    }

    @Test
    func concurrentEnqueuesRacingTeardownAllConclude() async throws {
        // Every caller must be resumed exactly once regardless of where it lands
        // relative to teardown: rejected up front, dropped by a terminated yield,
        // drained normally, or swept by the registry.
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )

        let callers = (0..<32).map { index in
            Task { try await writer.enqueue(Data("{\"id\":\(index)}".utf8)) }
        }
        // Tear down while the callers are still racing to enqueue.
        writer.finish()
        writer.cancel()
        await writer.join()

        // None of these awaits may hang; a double-resume would trap the checked
        // continuation instead.
        var concluded = 0
        for caller in callers {
            do { try await caller.value } catch { /* success or failure both fine */ }
            concluded += 1
        }
        #expect(concluded == callers.count)

        pipe.fileHandleForWriting.closeFile()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
    }

    @Test
    func enqueueAfterTeardownFailsInsteadOfHanging() async throws {
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )

        writer.finish()
        writer.cancel()
        await writer.join()

        do {
            try await writer.enqueue(Data(#"{"id":1}"#.utf8))
            Issue.record("Expected a post-teardown enqueue to fail.")
        } catch {
            // Expected: the job can never be drained after teardown.
        }

        pipe.fileHandleForWriting.closeFile()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
    }

    @Test
    func aCancelledCallerDoesNotEnqueueAWrite() async throws {
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )

        let cancelledCaller = Task {
            // Cancelled before it ever reaches enqueue().
            try await Task.sleep(nanoseconds: 10_000_000_000)
            try await writer.enqueue(Data(#"{"id":1}"#.utf8))
        }
        cancelledCaller.cancel()
        do { try await cancelledCaller.value } catch { /* expected */ }

        try await writer.enqueue(Data(#"{"id":2}"#.utf8))
        writer.finish()
        await writer.join()
        pipe.fileHandleForWriting.closeFile()

        let written = pipe.fileHandleForReading.readDataToEndOfFile()
        // Only the live request reached the bridge; no partial or stale frame.
        #expect(String(decoding: written, as: UTF8.self) == "{\"id\":2}\n")
    }

    @Test
    func aCancelledLocalRequestIsNotSentToTheBridge() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-cancel-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("mcp-fixture")
        let receivedURL = rootURL.appendingPathComponent("received.log")
        // The fixture answers initialize, then records every later request so the
        // test can assert that a cancelled tools/call never reaches the bridge.
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *notifications/initialized*)
              ;;
            *initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *)
              printf '%s\n' "$line" >> "\(receivedURL.path)"
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: executableURL.path,
                arguments: [],
                environment: [:]
            )
        )
        do {
            try await client.connect()

            let call = Task {
                try await client.callTool(named: "slow", arguments: [:])
            }
            call.cancel()
            do {
                _ = try await call.value
                Issue.record("Expected the cancelled tool call to throw.")
            } catch {
                // Expected: cancellation, not a bridge response.
            }

            // Give a regressed implementation time to deliver the write.
            try await Task.sleep(nanoseconds: 300_000_000)
            let received = (try? String(contentsOf: receivedURL, encoding: .utf8)) ?? ""
            #expect(!received.contains("tools/call"))
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()

        // Teardown must leave no live bridge behind.
        #expect(await client.process == nil)
        #expect(await client.inputHandle == nil)
    }

    @Test
    func disconnectConcludesInFlightRequestsAndClearsTheWriter() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-disconnect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("mcp-fixture")
        // Answers initialize, then never replies again: the pending request can
        // only be concluded by disconnect().
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *notifications/initialized*)
              ;;
            *initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: executableURL.path,
                arguments: [],
                environment: [:]
            )
        )
        try await client.connect()

        let pending = Task {
            try await client.callTool(named: "never-answered", arguments: [:])
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        await client.disconnect()

        do {
            _ = try await pending.value
            Issue.record("Expected the pending request to fail on disconnect.")
        } catch {
            // Expected: connectionClosed.
        }

        #expect(await client.process == nil)
        #expect(await client.writer == nil)
        #expect(await client.inputHandle == nil)
        #expect(await client.outputHandle == nil)
        #expect(await client.errorHandle == nil)
    }

    @Test
    func aCancelledQueuedJobIsWithdrawnBeforeReachingTheWire() async throws {
        // Regression: cancelling a request whose job is still QUEUED must retract
        // it. Previously `enqueue` had no cancellation handler, so a job already
        // buffered by the AsyncStream was written to the bridge as soon as the
        // wedged in-flight frame drained — delivering a request nobody awaits.
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )

        // Read the pipe only AFTER the cancellation, so the first frame stays
        // wedged on a full pipe buffer and the second job cannot be claimed.
        let readHandle = pipe.fileHandleForReading
        let inFlightPayload = Data(String(repeating: "x", count: 512 * 1024).utf8)
        let inFlightJob = Task { try await writer.enqueue(inFlightPayload) }
        // Happens-before: the first frame has bytes on the wire and is stalled.
        try await Self.waitUntilWedged(writer)

        let queuedJob = Task { try await writer.enqueue(Data(#"{"id":"queued"}"#.utf8)) }
        // Happens-before: the second job is observably registered and, since the
        // consumer is wedged on the first frame, it cannot have been claimed.
        try await Self.waitUntilQueuedBehindWedgedFrame(writer)

        // Exactly one frame is in flight; the second job is provably still
        // queued, which is the precondition this regression needs.
        #expect(writer.inFlightJobCount == 1)
        #expect(writer.queuedJobCount == 1)

        // Cancel while the job is still queued: it must never reach the wire.
        queuedJob.cancel()
        do {
            try await queuedJob.value
            Issue.record("Expected the cancelled queued job to throw.")
        } catch {
            // Expected: the job was withdrawn before any byte was written.
        }

        // Now let the wedged frame drain and collect everything the bridge saw.
        let collector = Task.detached { readHandle.readDataToEndOfFile() }
        try await inFlightJob.value

        writer.finish()
        await writer.join()
        pipe.fileHandleForWriting.closeFile()

        let written = await collector.value
        // The started frame completed intact...
        #expect(written.count == inFlightPayload.count + 1)
        #expect(written.last == 0x0A)
        // ...and the cancelled job contributed nothing at all.
        #expect(!String(decoding: written, as: UTF8.self).contains("queued"))
    }

    @Test
    func anInFlightFrameIsCompletedInsteadOfTruncatedOnCancellation() async throws {
        // The mirror invariant: once bytes of a frame are on the wire the job is
        // no longer withdrawable. Truncating it would corrupt the newline-framed
        // stream for every later message, so the frame is always completed.
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )

        let readHandle = pipe.fileHandleForReading
        let inFlightPayload = Data(String(repeating: "y", count: 512 * 1024).utf8)
        let inFlightJob = Task { try await writer.enqueue(inFlightPayload) }
        // Happens-before: bytes are on the wire and the pipe is full.
        try await Self.waitUntilWedged(writer)

        // The frame is already being written, so it is not withdrawable.
        #expect(writer.inFlightJobCount == 1)

        // Cancel the caller of the frame that is already partially written.
        inFlightJob.cancel()

        let collector = Task.detached { readHandle.readDataToEndOfFile() }
        _ = try? await inFlightJob.value

        writer.finish()
        await writer.join()
        pipe.fileHandleForWriting.closeFile()

        let written = await collector.value
        // Exactly one whole frame: no truncation, no duplicated tail.
        #expect(written.count == inFlightPayload.count + 1)
        #expect(written.last == 0x0A)
        #expect(written.dropLast() == inFlightPayload)
    }

    @Test
    func aSpontaneousBridgeExitClearsTheWriterAndAllowsAWorkingReconnect() async throws {
        // Regression: the termination handler closed stdin while the previous
        // generation's writer was still alive and still published on the actor.
        // A later connect() could inherit it, so writes went to a closed — and
        // possibly recycled — descriptor instead of the new bridge's stdin.
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-exit-reconnect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("mcp-fixture")
        let receivedURL = rootURL.appendingPathComponent("received.log")
        // Answers initialize, exits abruptly on `exit-now`, and records every
        // other request so the post-reconnect write can be observed on the wire.
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *notifications/initialized*)
              ;;
            *initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *exit-now*)
              exit 3
              ;;
            *)
              printf '%s\n' "$line" >> "\(receivedURL.path)"
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: executableURL.path,
                arguments: [],
                environment: [:]
            )
        )
        try await client.connect()

        // Provoke the spontaneous exit: the request can only fail.
        do {
            _ = try await client.callTool(named: "exit-now", arguments: [:])
            Issue.record("Expected the request to fail when the bridge exits.")
        } catch {
            // Expected: the exit is classified as a terminal bridge error.
        }

        // The termination handler runs asynchronously; wait for it to settle.
        var settled = false
        for _ in 0..<200 where !settled {
            if await client.process == nil, await client.writer == nil {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(settled)
        // The writer must be gone, not merely unused: a surviving writer is what
        // a reconnect would inherit.
        #expect(await client.writer == nil)
        #expect(await client.inputHandle == nil)
        #expect(await client.outputHandle == nil)
        #expect(await client.errorHandle == nil)

        // A terminal error is sticky, so clear it the way a caller would, then
        // reconnect the SAME client: this is the path that used to inherit the
        // previous generation's writer.
        await client.disconnect()
        try await client.connect()
        #expect(await client.writer != nil)

        // Prove the fresh writer targets the LIVE bridge's stdin: the fixture
        // records this request but never answers it.
        let afterReconnect = Task {
            try await client.callTool(named: "after-reconnect", arguments: [:])
        }
        var observedOnTheWire = false
        for _ in 0..<200 where !observedOnTheWire {
            let received = (try? String(contentsOf: receivedURL, encoding: .utf8)) ?? ""
            if received.contains("after-reconnect") {
                observedOnTheWire = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(observedOnTheWire)

        afterReconnect.cancel()
        _ = try? await afterReconnect.value
        await client.disconnect()
        #expect(await client.process == nil)
        #expect(await client.writer == nil)
    }

    @Test
    func teardownIsBoundedWhenTheWedgedPeerNeverDrainsTheInheritedReadEnd() async throws {
        // The exact finding: the bridge is gone but a DESCENDANT still holds the
        // read end open and never drains it. The frame already has bytes on the
        // wire, so it is not withdrawable, and the pipe never gains capacity.
        // Teardown must still terminate: an unbounded join here is a hard hang.
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor,
            teardownFrameGraceNanoseconds: 50_000_000
        )
        // `readHandle` stays open for the whole test and is NEVER read: this is
        // the descendant that inherited stdin. Keeping it open is what prevents
        // EPIPE from rescuing the write.
        let readHandle = pipe.fileHandleForReading

        let wedgedJob = Task { try await writer.enqueue(Data(String(repeating: "z", count: 512 * 1024).utf8)) }
        // Deterministic precondition: bytes on the wire AND stalled on EAGAIN.
        try await Self.waitUntilWedged(writer)

        let queuedJob = Task { try await writer.enqueue(Data(#"{"id":"queued"}"#.utf8)) }
        try await Self.waitUntilQueuedBehindWedgedFrame(writer)

        // Bounded teardown: this must return, and it must return without the peer
        // ever reading a single byte.
        _ = await writer.shutdown(timeoutNanoseconds: 2_000_000_000)

        // The consumer may be starved while the full suite is running. The
        // bounded shutdown contract therefore does not require it to finish
        // before this deadline: it requires the descriptor to be detached and
        // all caller continuations to be resolved so process teardown can make
        // progress safely either way.
        // Post-condition that makes closing the FD safe: no further write is
        // possible from this writer, whatever the consumer is still doing.
        #expect(!writer.isDescriptorValid)

        // Exactly-once: both callers are resolved, neither hangs, neither is
        // double-resumed (a double resume traps the checked continuation).
        var wedgedFailed = false
        do { try await wedgedJob.value } catch { wedgedFailed = true }
        var queuedFailed = false
        do { try await queuedJob.value } catch { queuedFailed = true }
        #expect(wedgedFailed)
        #expect(queuedFailed)

        pipe.fileHandleForWriting.closeFile()
        readHandle.closeFile()
    }

    @Test
    func aStaleWriterCannotWriteOnAClosedOrRecycledDescriptor() async throws {
        // Safety property behind the bounded teardown: once teardown detached the
        // descriptor, a straggling consumer must be unable to touch it. Otherwise
        // closing the FD without a join would let a late write land on whatever
        // the OS recycled that number into.
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor,
            teardownFrameGraceNanoseconds: 50_000_000
        )
        let readHandle = pipe.fileHandleForReading

        let wedgedJob = Task { try await writer.enqueue(Data(String(repeating: "w", count: 512 * 1024).utf8)) }
        try await Self.waitUntilWedged(writer)

        #expect(writer.isDescriptorValid)
        await writer.shutdown(timeoutNanoseconds: 2_000_000_000)
        #expect(!writer.isDescriptorValid)

        do { try await wedgedJob.value } catch { /* expected: abandoned frame */ }

        // Close the write end and drain the reader: the descriptor number is now
        // free for reuse. Any enqueue after teardown must fail rather than write.
        pipe.fileHandleForWriting.closeFile()
        do {
            try await writer.enqueue(Data(#"{"id":"late"}"#.utf8))
            Issue.record("A post-teardown enqueue must not reach a detached descriptor.")
        } catch {
            // Expected: the writer refuses the job instead of writing on the FD.
        }
        _ = readHandle.readDataToEndOfFile()
        readHandle.closeFile()
    }

    @Test
    func aCancelledTeardownBacksOffInsteadOfSpinning() async throws {
        // Regression: the EAGAIN back-off used `try? await Task.sleep`, which on
        // an ALREADY CANCELLED task returns immediately and turns the retry loop
        // into a CPU spin. The back-off must therefore be uninterruptible.
        //
        // Measured directly on the primitive: a cancelled task must still be
        // suspended for (approximately) the full interval.
        let interval: UInt64 = 200_000_000
        let spinning = Task {
            let start = DispatchTime.now()
            await MCPLocalTransportWriter.sleepIgnoringCancellation(nanoseconds: interval)
            return DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        }
        spinning.cancel()
        let elapsed = await spinning.value
        // A cancellation-aware sleep would return in ~0ns here.
        #expect(elapsed >= interval / 2)
    }

    @Test
    func aWedgedWriterDoesNotBlockASubsequentReconnect() async throws {
        // End-to-end shape of the finding: a previous generation's writer is
        // still wedged on a peer that never drains. Starting a new generation
        // must not wait for it, and the new writer must own a fresh descriptor.
        let stalePipe = Self.makeNonBlockingPipe()
        let staleReadEnd = stalePipe.fileHandleForReading
        let staleWriter = MCPLocalTransportWriter(
            fileDescriptor: stalePipe.fileHandleForWriting.fileDescriptor,
            teardownFrameGraceNanoseconds: 50_000_000
        )
        let staleJob = Task { try await staleWriter.enqueue(Data(String(repeating: "s", count: 512 * 1024).utf8)) }
        try await Self.waitUntilWedged(staleWriter)

        // This is the step that used to be unbounded.
        _ = await staleWriter.shutdown(timeoutNanoseconds: 2_000_000_000)
        #expect(!staleWriter.isDescriptorValid)
        do { try await staleJob.value } catch { /* expected */ }

        // A fresh generation works normally: bounded teardown must not leave the
        // writer in a permanently degraded state.
        let freshPipe = Self.makeNonBlockingPipe()
        let freshWriter = MCPLocalTransportWriter(
            fileDescriptor: freshPipe.fileHandleForWriting.fileDescriptor
        )
        try await freshWriter.enqueue(Data(#"{"id":"fresh"}"#.utf8))
        await freshWriter.shutdown()
        freshPipe.fileHandleForWriting.closeFile()
        let written = freshPipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: written, as: UTF8.self) == "{\"id\":\"fresh\"}\n")

        stalePipe.fileHandleForWriting.closeFile()
        _ = staleReadEnd.readDataToEndOfFile()
        staleReadEnd.closeFile()
        freshPipe.fileHandleForReading.closeFile()
    }

    @Test
    func aStartedFrameIsStillCompletedWhenThePeerDrainsDuringNormalOperation() async throws {
        // The counterpart invariant: bounded teardown must not become an excuse
        // to truncate frames while the peer is alive. A slow-but-draining reader
        // must still receive the frame whole.
        let pipe = Self.makeNonBlockingPipe()
        let writer = MCPLocalTransportWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor,
            teardownFrameGraceNanoseconds: 50_000_000
        )
        let readHandle = pipe.fileHandleForReading
        let payload = Data(String(repeating: "d", count: 512 * 1024).utf8)

        let job = Task { try await writer.enqueue(payload) }
        try await Self.waitUntilWedged(writer)

        // The peer starts draining: progress must reset the stall budget, so the
        // frame completes intact even though teardown begins meanwhile.
        let collector = Task.detached { readHandle.readDataToEndOfFile() }
        try await job.value

        await writer.shutdown()
        pipe.fileHandleForWriting.closeFile()
        let written = await collector.value
        #expect(written.count == payload.count + 1)
        #expect(written.dropLast() == payload)
        #expect(written.last == 0x0A)
        readHandle.closeFile()
    }

    /// Deterministic happens-before: returns only once the writer has PROVABLY
    /// claimed a job, put bytes on the wire and hit `EAGAIN` on a full pipe.
    /// Polling an observable state transition (not a fixed sleep) is what makes
    /// the "wedged writer" precondition reliable rather than timing-dependent.
    private static func waitUntilWedged(
        _ writer: MCPLocalTransportWriter
    ) async throws {
        for _ in 0..<20_000 {
            if writer.inFlightJobCount == 1, writer.didStallInFlightFrame {
                return
            }
            try await Task.sleep(nanoseconds: 500_000)
        }
        Issue.record("Timed out waiting for the writer to wedge on a full pipe.")
    }

    /// Deterministic happens-before for a job that must be observably QUEUED:
    /// the wedged frame owns the consumer, so the next enqueue can only be
    /// sitting in the registry.
    private static func waitUntilQueuedBehindWedgedFrame(
        _ writer: MCPLocalTransportWriter
    ) async throws {
        try await waitUntilQueuedCount(writer, atLeast: 1)
    }

    /// Waits until at least `atLeast` jobs are observably registered-but-unclaimed.
    private static func waitUntilQueuedCount(
        _ writer: MCPLocalTransportWriter,
        atLeast count: Int
    ) async throws {
        for _ in 0..<20_000 {
            if writer.queuedJobCount >= count {
                return
            }
            try await Task.sleep(nanoseconds: 500_000)
        }
        Issue.record("Timed out waiting for \(count) queued job(s).")
    }
}
#endif
