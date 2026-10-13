// TerminalCursorReportTests.swift
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite(TerminalBlockingTestScope())
struct TerminalCursorReportTests {
    private func drain(_ input: TerminalRawInput, count: Int) -> String {
        var bytes: [UInt8] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        // A poll may time out while the CPR callback still owns the input.
        // Count delivered bytes, not poll attempts, so that handoff cannot
        // silently consume one of the expected key slots.
        while bytes.count < count, ContinuousClock.now < deadline {
            if let byte = input.readByte(timeoutMilliseconds: 100) { bytes.append(byte) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func fragmentedReportPreservesOrdinaryKeysAndPaste() async throws {
        let reports = TerminalCursorReport()
        let pipe = Pipe()
        let input = TerminalRawInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: reports)
        let received = Mutex<TerminalCursorReport.Position?>(nil)
        #expect(reports.request { result in
            if case let .success(position) = result { received.withLock { $0 = position } }
        })
        let paste = "\u{1B}[200~literal \u{1B}[3;2R\u{1B}[201~"
        pipe.fileHandleForWriting.write(Data(("a" + paste + "\u{1B}[").utf8))
        #expect(input.readByteResult(timeoutMilliseconds: 5) == .timedOut)
        pipe.fileHandleForWriting.write(Data("12;".utf8))
        #expect(input.readByteResult(timeoutMilliseconds: 5) == .timedOut)
        pipe.fileHandleForWriting.write(Data("1Rb".utf8))
        let expected = "a" + paste + "b"
        #expect(drain(input, count: expected.utf8.count) == expected)
        #expect(received.withLock { $0 } == .init(row: 12, column: 1))
    }

    @Test func timeoutFencesQueriesAndDrainsExactlyOneLateReport() async throws {
        let reports = TerminalCursorReport()
        let pipe = Pipe()
        let input = TerminalRawInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: reports)
        let failure = Mutex<TerminalCursorReport.Failure?>(nil)
        #expect(reports.request(timeout: 0.02) { result in
            if case let .failure(value) = result { failure.withLock { $0 = value } }
        })
        pipe.fileHandleForWriting.write(Data("x\u{1B}[19;".utf8))
        _ = input.readByteResult(timeoutMilliseconds: 5)
        try await terminalWaitForCursorReport(reports)
        #expect(failure.withLock { $0 } == .timeout)
        #expect(!reports.request { _ in Issue.record("anonymous retry must not be armed") })
        pipe.fileHandleForWriting.write(Data("1Ry\u{1B}[1;2R".utf8))
        // Late CPR is consumed once; modified F3 is an ordinary key afterwards.
        let expected = "xy\u{1B}[1;2R"
        #expect(drain(input, count: expected.utf8.count) == expected)
        #expect(reports.isFenced)
    }

    @Test func queryRejectsFragmentedPasteOpeningWithoutLosingBytes() {
        let reports = TerminalCursorReport()
        let prefix = "\u{1B}[20"
        for byte in prefix.utf8 { #expect(reports.consume(byte).isEmpty) }
        #expect(!reports.request { _ in Issue.record("A partial paste must not arm CPR") })
        let suffix = "0~literal \u{1B}[10;1R\u{1B}[201~"
        let bytes = suffix.utf8.flatMap { reports.consume($0) }
        #expect(String(decoding: bytes, as: UTF8.self) == prefix + suffix)
        #expect(!reports.isHoldingInput)
    }

    @Test func timeoutWithoutReplyDoesNotTurnNewEscapeAndFIntoMetaF() async throws {
        let reports = TerminalCursorReport()
        let pipe = Pipe()
        let raw = TerminalRawInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: reports)
        let reader = TerminalInteractiveLineReader(rawInput: raw)
        let timedOut = Mutex(false)
        #expect(reports.request(timeout: 0.02) { result in
            if case .failure(.timeout) = result { timedOut.withLock { $0 = true } }
        })
        try await terminalWaitForCursorReport(reports)
        #expect(timedOut.withLock { $0 })
        pipe.fileHandleForWriting.write(Data([27]))
        #expect(reader.readKeyResult(pollTimeoutMilliseconds: 100) == .key(.cancel))
        pipe.fileHandleForWriting.write(Data("f".utf8))
        #expect(reader.readKeyResult(pollTimeoutMilliseconds: 100) == .key(.character("f")))
        // A NEW truncated numeric prefix is ordinary input, not old CPR state.
        pipe.fileHandleForWriting.write(Data("\u{1B}[42;".utf8))
        #expect(drain(raw, count: 5) == "\u{1B}[42;")
    }

    @Test func oldTruncatedReportPrefixHasABoundedGracePeriod() {
        let clock = Mutex(ContinuousClock.now)
        let reports = TerminalCursorReport(now: { clock.withLock { $0 } })
        #expect(reports.request { _ in })
        let prefix = "\u{1B}[19;"
        for byte in prefix.utf8 { #expect(reports.consume(byte).isEmpty) }
        reports.cancel()
        #expect(reports.releaseOrdinaryPrefix().isEmpty)
        clock.withLock { $0 = $0.advanced(by: .seconds(1)) }
        #expect(String(decoding: reports.releaseOrdinaryPrefix(), as: UTF8.self) == prefix)
        #expect(reports.releaseOrdinaryPrefix().isEmpty)
        #expect(reports.consume(27).isEmpty)
        #expect(reports.releaseOrdinaryPrefix() == [27])
        #expect(reports.consume(102) == [102])
    }

    @Test func ordinaryCSIAndModifiedF3OutsideHandshakeAreNeverConsumed() {
        let pipe = Pipe()
        let input = TerminalRawInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)
        let keys = "a\u{1B}[A\u{1B}[1;2R\u{1B}OPz"
        pipe.fileHandleForWriting.write(Data(keys.utf8))
        #expect(drain(input, count: keys.utf8.count) == keys)
    }

    @Test func cancellationAndRejectedCoordinatesFailClosed() async throws {
        for rejected in [false, true] {
            let reports = TerminalCursorReport()
            let result = Mutex<TerminalCursorReport.Failure?>(nil)
            #expect(reports.request { value in
                if case let .failure(failure) = value { result.withLock { $0 = failure } }
            })
            if rejected { for byte in "\u{1B}[0;1R".utf8 { _ = reports.consume(byte) } }
            else { reports.cancel() }
            try await terminalWaitForCursorReport(reports)
            #expect(result.withLock { $0 } == (rejected ? .rejected : .cancelled))
            #expect(reports.isFenced)
            #expect(!reports.request { _ in })
        }
    }

    @Test func injectedDiagnosticsObserveTheRealReaderWithoutStealingReportOrKeys() async throws {
        let events = Mutex<[String]>([])
        let reports = TerminalCursorReport(diagnostic: { event in
            events.withLock { $0.append(event) }
        })
        let pipe = Pipe()
        let raw = TerminalRawInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: reports)
        let reader = TerminalInteractiveLineReader(rawInput: raw)
        let position = Mutex<TerminalCursorReport.Position?>(nil)
        #expect(reports.request { result in
            if case let .success(value) = result { position.withLock { $0 = value } }
        })
        pipe.fileHandleForWriting.write(Data("x\u{1B}[19;1Ry".utf8))
        #expect(reader.readKeyResult(pollTimeoutMilliseconds: 200) == .key(.character("x")))
        #expect(reader.readKeyResult(pollTimeoutMilliseconds: 200) == .key(.character("y")))
        #expect(position.withLock { $0 } == .init(row: 19, column: 1))
        let trace = events.withLock { $0 }
        #expect(trace.contains { $0.hasPrefix("report.armed id=") })
        #expect(trace.contains("raw.device.byte=27"))
        #expect(trace.contains { $0.hasPrefix("report.parsed id=") && $0.hasSuffix("row=19 column=1") })
        #expect(trace.contains { $0.hasPrefix("report.delivery.begin result=") })
        #expect(!trace.contains { $0.hasPrefix("report.failure ") })
    }

    @Test func injectedDiagnosticsIdentifyCancellationAndBufferedPrefix() {
        let events = Mutex<[String]>([])
        let reports = TerminalCursorReport(diagnostic: { event in events.withLock { $0.append(event) } })
        #expect(reports.request { _ in })
        for byte in "\u{1B}[19;".utf8 { _ = reports.consume(byte) }
        reports.cancel()
        #expect(events.withLock { $0.contains { $0.hasPrefix("report.failure id=") && $0.contains("reason=cancelled prefixCount=5") } })
        #expect(reports.isFenced)
    }

    @Test func aSuspendedResizeQueuesKeysBeforeTheQueryWithoutASecondReader() async throws {
        let reports = TerminalCursorReport()
        let pipe = Pipe()
        let input = TerminalRawInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: reports)
        reports.suspendInput()
        pipe.fileHandleForWriting.write(Data("draft".utf8))
        #expect(input.readByteResult(timeoutMilliseconds: 5) == .timedOut)
        #expect(reports.request { _ in })
        pipe.fileHandleForWriting.write(Data("\u{1B}[8;1R".utf8))
        #expect(drain(input, count: 5) == "draft")
    }
}
