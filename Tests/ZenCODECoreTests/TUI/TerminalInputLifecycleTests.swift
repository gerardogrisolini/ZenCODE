//
//  TerminalInputLifecycleTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Covers the lifecycle of the blocking terminal readers: panel ownership
/// hand-over, cancellation-aware line/menu reads, and the ESC stop monitor.
///
/// Ordering is expressed with signals and state predicates rather than sleeps:
/// these tests are about interleavings, and a sleep-based test silently stops
/// covering its interleaving when the machine is loaded.
@Suite(.timeLimit(.minutes(1)))
struct TerminalInputLifecycleTests {
    /// A pipe whose write end stays open, so reads block exactly like an idle
    /// terminal instead of reporting end-of-input.
    private func makeIdleInput() -> (pipe: Pipe, rawInput: TerminalRawInput) {
        let pipe = Pipe()
        let rawInput = TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor
        )
        return (pipe, rawInput)
    }

    @Test
    func cancellingALineReadUnblocksItOnAnIdleTerminal() async {
        let input = makeIdleInput()
        defer {
            input.pipe.fileHandleForWriting.closeFile()
            input.pipe.fileHandleForReading.closeFile()
        }
        let reader = TerminalInteractiveLineReader(rawInput: input.rawInput)
        let didStartReading = TerminalTestSignal()

        let task = Task {
            didStartReading.signal()
            return await TerminalChat.readLineOffActor(reader: reader, prompt: "")
        }
        // Cancel only once the read has been entered, so the test covers an
        // in-flight read rather than the bridge's entry guard.
        await didStartReading.wait()
        task.cancel()

        // Without cancellation support this would hang until a key arrives.
        #expect(await task.value == nil)
    }

    @Test
    func cancellingAConsentReadUnblocksItOnAnIdleTerminal() async {
        let input = makeIdleInput()
        defer {
            input.pipe.fileHandleForWriting.closeFile()
            input.pipe.fileHandleForReading.closeFile()
        }
        let reader = TerminalInteractiveLineReader(rawInput: input.rawInput)
        let didStartReading = TerminalTestSignal()

        let task = Task {
            didStartReading.signal()
            return await TerminalChat.readConsentKeyOffActor(reader: reader, prompt: "")
        }
        await didStartReading.wait()
        task.cancel()

        #expect(await task.value == nil)
    }

    @Test
    func cancellableLineReadStillReturnsSubmittedInput() async {
        let pipe = Pipe()
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            )
        )
        let didStartReading = TerminalTestSignal()

        let line = Task { () -> String? in
            didStartReading.signal()
            return await TerminalChat.readLineOffActor(reader: reader, prompt: "")
        }
        // The read is a poll loop over a pipe, so input written after it starts
        // is picked up on the next poll; signalling replaces the arbitrary sleep
        // without changing what is being read.
        await didStartReading.wait()
        pipe.fileHandleForWriting.write(Data("hi\r".utf8))

        // UX unchanged: a normal submission still resolves to its text.
        #expect(await line.value == "hi")
        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func panelInputLoopStopsPromptlyWhenTheReadTokenIsCancelled() async {
        let input = makeIdleInput()
        defer {
            input.pipe.fileHandleForWriting.closeFile()
            input.pipe.fileHandleForReading.closeFile()
        }
        let reader = TerminalInteractiveLineReader(rawInput: input.rawInput)
        let statusBar = TerminalStatusBar(isEnabled: false)
        let receivedEvents = Mutex(0)

        let loop = Task {
            await reader.runPanelInputLoop(statusBar: statusBar) { _ in
                receivedEvents.withLock { $0 += 1 }
            }
        }
        // Token publication precedes dispatching the blocking worker. Wait for
        // the worker's marker immediately before its raw read instead, so the
        // latency below cannot include dispatch-queue scheduling time.
        await terminalWaitUntil {
            reader.withPanelLock { $0.panelReadToken?.hasEnteredBlockingRead == true }
        }

        // `stopPanelInput` cancels this token before awaiting the loop task, so
        // teardown does not wait out the pending read window.
        let clock = ContinuousClock()
        let start = clock.now
        reader.withPanelLock { state in
            state.panelReadToken?.cancel()
        }
        loop.cancel()
        await loop.value
        let elapsed = start.duration(to: clock.now)

        // Cancellation is observed by the 50 ms polling read. This generous
        // margin covers a loaded test executor without hiding a stalled read.
        #expect(elapsed < .seconds(1))
        // No spurious events are emitted while tearing down.
        #expect(receivedEvents.withLock { $0 } == 0)
    }

    @Test
    func aStartIsNotAdmittedWhileAStopIsStillUnwinding() async {
        // The ownership invariant: a stop is finished when it has awaited the
        // loop task *and* restored raw mode, not when it clears `panelTask`. A
        // start admitted in between would acquire a terminal that the
        // predecessor's `restoreRawMode()` is about to reset under it.
        let reader = TerminalInteractiveLineReader()
        let statusBar = TerminalStatusBar(isEnabled: false)

        // Simulate a teardown in flight: the stop has claimed the panel and is
        // suspended before `finishPanelStop`.
        let claim = await reader.claimPanelForStop()
        #expect(claim.task == nil)

        let admission = Mutex<TerminalInteractiveLineReader.PanelStartAdmission?>(nil)
        let start = Task {
            let result = await reader.admitPanelStart(
                statusBar: statusBar,
                commandSuggestions: [],
                preservingState: false
            )
            admission.withLock { $0 = result }
        }

        // The panel is `stopping`, so the start must park instead of claiming
        // the terminal. Its synchronous probe reports exactly that.
        await terminalWaitUntil {
            reader.withPanelLock { !$0.panelTransitionWaiters.isEmpty }
        }
        #expect(admission.withLock { $0 } == nil)

        // Completing the stop is what releases the start.
        reader.finishPanelStop(clearPanel: true)
        await start.value
        #expect(admission.withLock { $0 } == .admitted)

        reader.abandonPanelStart()
    }

    @Test
    func aStopIsNotAdmittedWhileAStartIsStillAcquiringTheTerminal() async {
        // The mirror invariant: during `starting` the new loop task is not
        // published yet, so a stop admitted there would await nothing, restore
        // raw mode under the incoming reader, and leave it on a cooked terminal.
        let reader = TerminalInteractiveLineReader()
        let statusBar = TerminalStatusBar(isEnabled: false)

        #expect(
            reader.preparePanelForStart(
                statusBar: statusBar,
                commandSuggestions: [],
                preservingState: false
            ) == .admitted
        )
        // A stop cannot claim a panel that is mid-start.
        #expect(reader.takePanelTaskForStop() == nil)

        let didStop = TerminalTestSignal()
        let stop = Task {
            let claim = await reader.claimPanelForStop()
            didStop.signal()
            reader.finishPanelStop(clearPanel: true)
            return claim.task
        }

        await terminalWaitUntil {
            reader.withPanelLock { !$0.panelTransitionWaiters.isEmpty }
        }
        #expect(!didStop.isSignalled)

        // Publishing the running panel hands the stop a task to await.
        let loop = Task<Void, Never> {}
        reader.finishPanelStart(task: loop)

        #expect(await stop.value != nil)
        #expect(didStop.isSignalled)
    }

    @Test
    func aSecondStartIsRejectedWhileThePanelIsRunning() async {
        // Concurrent starts must not both take the terminal; the loser is told
        // the panel is already active instead of being parked forever.
        let reader = TerminalInteractiveLineReader()
        let statusBar = TerminalStatusBar(isEnabled: false)

        #expect(
            reader.preparePanelForStart(
                statusBar: statusBar,
                commandSuggestions: [],
                preservingState: false
            ) == .admitted
        )
        let loop = Task<Void, Never> {}
        reader.finishPanelStart(task: loop)

        let second = await reader.admitPanelStart(
            statusBar: statusBar,
            commandSuggestions: [],
            preservingState: false
        )
        #expect(second == .alreadyActive)

        let claim = await reader.claimPanelForStop()
        #expect(claim.task != nil)
        reader.finishPanelStop(clearPanel: true)
    }

    @Test
    func aFailedStartReleasesThePanelForTheNextCaller() async {
        // A start that cannot acquire raw mode must not strand the panel in
        // `starting`, or every later start and stop would park forever.
        let reader = TerminalInteractiveLineReader()
        let statusBar = TerminalStatusBar(isEnabled: false)

        #expect(
            reader.preparePanelForStart(
                statusBar: statusBar,
                commandSuggestions: [],
                preservingState: false
            ) == .admitted
        )
        reader.abandonPanelStart()

        #expect(
            await reader.admitPanelStart(
                statusBar: statusBar,
                commandSuggestions: [],
                preservingState: false
            ) == .admitted
        )
        reader.abandonPanelStart()
    }

    @Test
    func panelReadStandsDownWhileConsentOwnsTheTerminal() async {
        let input = makeIdleInput()
        defer {
            input.pipe.fileHandleForWriting.closeFile()
            input.pipe.fileHandleForReading.closeFile()
        }
        let reader = TerminalInteractiveLineReader(rawInput: input.rawInput)

        await TerminalConsentInputOwnership.beginConsent()
        defer { TerminalConsentInputOwnership.endConsent() }

        let token = TerminalBlockingReadToken()
        // A byte is available, but the panel must not consume it: it belongs to
        // the consent prompt that currently owns the terminal.
        input.pipe.fileHandleForWriting.write(Data([0x72]))
        let result = TerminalInteractiveLineReader.readPanelKeyResult(
            reader: reader,
            token: token
        )
        #expect(result == .timedOut)
    }

    @Test
    func panelReadReportsCancellationRatherThanAKey() {
        let input = makeIdleInput()
        defer {
            input.pipe.fileHandleForWriting.closeFile()
            input.pipe.fileHandleForReading.closeFile()
        }
        let reader = TerminalInteractiveLineReader(rawInput: input.rawInput)

        let token = TerminalBlockingReadToken()
        token.cancel()
        #expect(
            TerminalInteractiveLineReader.readPanelKeyResult(
                reader: reader,
                token: token
            ) == nil
        )
    }

    @Test
    func cancelledMenuReadReportsEndOfInputInsteadOfBlocking() {
        let input = makeIdleInput()
        defer {
            input.pipe.fileHandleForWriting.closeFile()
            input.pipe.fileHandleForReading.closeFile()
        }

        let token = TerminalBlockingReadToken()
        token.cancel()
        // A cancelled menu unwinds like an operator cancel instead of holding
        // the terminal until a key is pressed.
        #expect(
            TerminalCheckboxMenu.readByte(
                rawInput: input.rawInput,
                shouldCancel: token.isCancelled
            ) == nil
        )
        #expect(
            TerminalCheckboxMenu.readKey(
                rawInput: input.rawInput,
                shouldCancel: token.isCancelled
            ) == nil
        )
    }

    @Test
    func menuReadReturnsAKeyWhenNotCancelled() {
        let pipe = Pipe()
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        let rawInput = TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor
        )
        pipe.fileHandleForWriting.write(Data([0x20]))

        // UX unchanged: space still toggles the focused item.
        #expect(
            TerminalCheckboxMenu.readKey(
                rawInput: rawInput,
                shouldCancel: { false }
            ) == .toggle
        )
        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func escapeStopMonitorUnwindsOnCancellationWithoutFiringStop() async {
        let didStop = TerminalTestFlag()
        let token = TerminalBlockingReadToken()
        let didStartWatching = TerminalTestSignal()
        let input = makeIdleInput()
        defer {
            input.pipe.fileHandleForWriting.closeFile()
            input.pipe.fileHandleForReading.closeFile()
        }
        let rawInput = input.rawInput

        let watch = Task.detached {
            return TerminalEscapeStopMonitor.watchForEscape(
                token: token,
                rawInput: rawInput,
                managesRawMode: false,
                onPollStarted: { didStartWatching.signal() }
            ) {
                didStop.set(true)
            }
        }
        await didStartWatching.wait()
        token.cancel()

        // Returns `false` (cancelled) or `nil` (no terminal available in the
        // test environment); in neither case may it report a stop request.
        #expect(await watch.value != true)
        #expect(!didStop.value)
    }

    @Test
    func foregroundRecoveryTargetsOnlyAStaleDifferentOwner() {
        #expect(
            !TerminalRawInput.shouldReclaimForegroundTerminal(
                foregroundProcessGroup: 202,
                currentProcessGroup: 202,
                foregroundProcessGroupExists: true
            )
        )
        #expect(
            !TerminalRawInput.shouldReclaimForegroundTerminal(
                foregroundProcessGroup: 101,
                currentProcessGroup: 202,
                foregroundProcessGroupExists: true
            )
        )
        #expect(
            TerminalRawInput.shouldReclaimForegroundTerminal(
                foregroundProcessGroup: 101,
                currentProcessGroup: 202,
                foregroundProcessGroupExists: false
            )
        )
    }

    @Test
    func escapeStopMonitorIsNotStartedWhenDisabled() {
        #expect(
            TerminalEscapeStopMonitor.startIfNeeded(isEnabled: false, onStop: {}) == nil
        )
    }
}
