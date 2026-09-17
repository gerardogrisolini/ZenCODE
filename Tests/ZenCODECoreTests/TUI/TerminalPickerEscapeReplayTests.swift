//
//  TerminalPickerEscapeReplayTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct TerminalPickerEscapeReplayTests {
    private func pickerReader(
        pipe: Pipe,
        base: Character = "O",
        ownership: TerminalConsentInputOwnership = TerminalConsentInputOwnership()
    ) -> TerminalInteractiveLineReader {
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor),
            consentInputOwnership: ownership
        )
        reader.withPanelLock { state in
            state.panelSupportsPressAndHold = true
            for timestamp in [UInt64(0), 500, 550, 600, 650] {
                _ = state.editor.apply(
                    .character(String(base)),
                    context: reader.editorContextLocked(state: state),
                    timestampMilliseconds: timestamp
                )
            }
        }
        return reader
    }

    @Test(arguments: ["a", "O"])
    func compoundEscapeUsesReadTimestampRatherThanStaleMenuTimestamp(base: String) async throws {
        let pipe = Pipe()
        defer {
            pipe.fileHandleForWriting.closeFile()
            pipe.fileHandleForReading.closeFile()
        }
        let character = try #require(base.first)
        let reader = pickerReader(pipe: pipe, base: character)
        pipe.fileHandleForWriting.write(Data(("\u{1B}" + base + base).utf8))
        let timed = try #require(TerminalInteractiveLineReader.readTimedPanelKeyResult(
            reader: reader,
            token: TerminalBlockingReadToken()
        ))
        #expect(timed.result == .pickerEscape(consumedRepeat: character))
        #expect(timed.timestampMilliseconds > 650 + TerminalPressAndHold.residualRepeatWindowMilliseconds)
        await reader.handlePanelKey(
            .cancel,
            timestampMilliseconds: timed.timestampMilliseconds,
            consumedPickerRepeat: timed.result.consumedPickerRepeat
        ) { _ in Issue.record("Compound Escape must not emit a panel action") }
        #expect(reader.withPanelLock {
            $0.editor.pressAndHoldSuppression?.lastRepeatTimestampMilliseconds
        } == timed.timestampMilliseconds)
        #expect(TerminalInteractiveLineReader.readPanelKeyResult(
            reader: reader,
            token: TerminalBlockingReadToken()
        ) == .key(.character(base)))
        await reader.handlePanelKey(.character(base), timestampMilliseconds: timed.timestampMilliseconds + 10) { _ in
            Issue.record("Residual repeat must not emit a panel action")
        }
        #expect(reader.withPanelLock { String($0.panelBuffer) } == base)
    }

    @Test
    func plainEscapeDoesNotPretendToHaveObservedARepeat() async throws {
        let pipe = Pipe()
        defer {
            pipe.fileHandleForWriting.closeFile()
            pipe.fileHandleForReading.closeFile()
        }
        let reader = pickerReader(pipe: pipe, base: "a")
        pipe.fileHandleForWriting.write(Data([0x1B]))
        let result = try #require(TerminalInteractiveLineReader.readPanelKeyResult(
            reader: reader,
            token: TerminalBlockingReadToken()
        ))
        #expect(result == .key(.cancel))
        #expect(result.consumedPickerRepeat == nil)
        await reader.handlePanelKey(.cancel, timestampMilliseconds: 4_000) { _ in }
        await reader.handlePanelKey(.character("a"), timestampMilliseconds: 4_010) { _ in }
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "aa")
    }

    @Test(arguments: [false, true])
    func failedSS3ProbeReplaysAllLookaheadInOrderAtTimeoutEOFAndLengthLimit(closeWriter: Bool) {
        let suffixes: [[UInt8]] = [
            [],
            [0x1B, 0x5B, 0x44], // An independent CSI left key.
            [0x0D],             // An independent Enter key.
            [0x4F, 0x4F],       // Repeated base letters are not SS3.
            [0xFF, 0x61],
            Array("12;!tail".utf8),
            Array("12".utf8),   // Incomplete parameters: rollback on timeout/EOF.
            Array(repeating: 0x31, count: TerminalInteractiveLineReader.escapeSequenceMaximumLength) + Array("TAIL".utf8)
        ]
        for suffix in suffixes {
            let pipe = Pipe()
            defer {
                if !closeWriter { pipe.fileHandleForWriting.closeFile() }
                pipe.fileHandleForReading.closeFile()
            }
            let reader = pickerReader(pipe: pipe)
            pipe.fileHandleForWriting.write(Data([0x1B, 0x4F] + suffix))
            if closeWriter { pipe.fileHandleForWriting.closeFile() }
            #expect(TerminalInteractiveLineReader.readPanelKeyResult(
                reader: reader,
                token: TerminalBlockingReadToken()
            ) == .pickerEscape(consumedRepeat: "O"))
            // Read through the raw-input API as well: rollback is owned there,
            // not hidden in a parser-local buffer that another reader can skip.
            for byte in suffix {
                #expect(reader.rawInput.readByteResult(timeoutMilliseconds: 0) == .byte(byte))
            }
            #expect(reader.rawInput.readByteResult(timeoutMilliseconds: 0) == (closeWriter ? .endOfInput : .timedOut))
        }
    }

    @Test
    func validSS3KeysKeepPriorityAndDoNotConsumeTheFollowingByte() {
        let cases: [([UInt8], TerminalInteractiveLineReader.Key)] = [
            ([0x41], .up), ([0x42], .down), ([0x43], .right), ([0x44], .left),
            ([0x46], .end), ([0x48], .home),
            (Array("1;2D".utf8), .left),
            ([0x50], .unknown), // F1 remains a consumed unsupported key.
            ([0x70], .unknown)  // Application keypad zero retains its semantics.
        ]
        for (continuation, key) in cases {
            let pipe = Pipe()
            defer {
                pipe.fileHandleForWriting.closeFile()
                pipe.fileHandleForReading.closeFile()
            }
            let reader = pickerReader(pipe: pipe)
            pipe.fileHandleForWriting.write(Data([0x1B, 0x4F] + continuation + [0x21]))
            #expect(TerminalInteractiveLineReader.readPanelKeyResult(
                reader: reader,
                token: TerminalBlockingReadToken()
            ) == .key(key))
            #expect(reader.readKeyResult(pollTimeoutMilliseconds: 0) == .key(.character("!")))
        }
    }

    @Test
    func liveLoopPreservesCSIAndEnterAfterCompoundEscapeAndSuppressesQueuedRepeats() async {
        let cases: [(base: Character, bytes: [UInt8], draft: String, cursor: Int, submitted: [String])] = [
            ("O", [0x1B, 0x4F, 0x1B, 0x5B, 0x44], "O", 0, []),
            ("O", [0x1B, 0x4F, 0x0D], "", 0, ["O"]),
            ("O", [0x1B, 0x4F, 0x4F, 0x4F], "O", 1, []),
            ("a", [0x1B, 0x61, 0x61, 0x61], "a", 1, []),
            // A valid SS3 is navigation inside the picker, not dismissal.
            ("O", [0x1B, 0x4F, 0x44, 0x0D], "Õ", 1, [])
        ]
        for testCase in cases {
            let pipe = Pipe()
            defer { pipe.fileHandleForReading.closeFile() }
            let reader = pickerReader(pipe: pipe, base: testCase.base)
            let submitted = Mutex<[String]>([])
            let reachedEOF = Mutex(false)
            pipe.fileHandleForWriting.write(Data(testCase.bytes))
            pipe.fileHandleForWriting.closeFile()
            await reader.runPanelInputLoop(statusBar: TerminalStatusBar(isEnabled: false)) { event in
                switch event {
                case let .submitted(line): submitted.withLock { $0.append(line) }
                case .endOfInput: reachedEOF.withLock { $0 = true }
                default: Issue.record("Unexpected panel action")
                }
            }
            #expect(reachedEOF.withLock { $0 })
            #expect(submitted.withLock { $0 } == testCase.submitted)
            #expect(reader.withPanelLock { String($0.panelBuffer) } == testCase.draft)
            #expect(reader.withPanelLock { $0.panelCursorIndex } == testCase.cursor)
        }
    }

    @Test
    func isolatedConsentTimeoutDoesNotConsumePipeAndReadCanBeRetried() async {
        let pipe = Pipe()
        defer {
            pipe.fileHandleForWriting.closeFile()
            pipe.fileHandleForReading.closeFile()
        }
        let ownership = TerminalConsentInputOwnership()
        let reader = pickerReader(pipe: pipe, ownership: ownership)
        pipe.fileHandleForWriting.write(Data([0x1B, 0x4F, 0x0D]))
        await ownership.beginConsent()
        let blocked = TerminalInteractiveLineReader.readPanelKeyResult(
            reader: reader,
            token: TerminalBlockingReadToken()
        )
        ownership.endConsent()
        #expect(blocked == .timedOut)
        #expect(TerminalInteractiveLineReader.readPanelKeyResult(
            reader: reader,
            token: TerminalBlockingReadToken()
        ) == .pickerEscape(consumedRepeat: "O"))
        #expect(TerminalInteractiveLineReader.readPanelKeyResult(
            reader: reader,
            token: TerminalBlockingReadToken()
        ) == .key(.enter))
    }
}
