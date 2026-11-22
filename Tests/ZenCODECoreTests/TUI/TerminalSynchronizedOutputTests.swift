//
//  TerminalSynchronizedOutputTests.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

private final class SynchronizedOutputCapture: Sendable {
    private let items = Mutex<[String]>([])
    func append(_ text: String) { items.withLock { $0.append(text) } }
    var writes: [String] { items.withLock { $0 } }
}

@Suite("TerminalSynchronizedOutput", .serialized, TerminalBlockingTestScope())
struct TerminalSynchronizedOutputTests {
    private final class Owner {}

    private static let begin = "\u{1B}[?2026h"
    private static let end = "\u{1B}[?2026l"
    private static let marker = "\u{1B}[?2026"

    /// A restoration whose handlers are never installed: no process-wide state.
    private static func isolatedRestoration() -> TerminalSignalRestoration {
        TerminalSignalRestoration(
            installHandlers: { _ in {} },
            terminate: { _ in }
        )
    }

    private static func drain(_ pipe: Pipe) throws -> String {
        try pipe.fileHandleForWriting.close()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // MARK: - Frame

    @Test("A frame encloses the text in exactly one begin/end pair")
    func frameEnclosesText() {
        #expect(TerminalSynchronizedOutput.begin == "\u{1B}[?2026h")
        #expect(TerminalSynchronizedOutput.end == "\u{1B}[?2026l")
        #expect(TerminalSynchronizedOutput.frame("abc") == "\u{1B}[?2026habc\u{1B}[?2026l")
        #expect(TerminalSynchronizedOutput.frame("\u{1B}[2K\r\nx") == "\u{1B}[?2026h\u{1B}[2K\r\nx\u{1B}[?2026l")
    }

    // MARK: - Production path (no sink)

    @Test("A production write reaches the terminal as one frame")
    func productionWriteIsOneFrame() throws {
        let pipe = Pipe()
        let restoration = Self.isolatedRestoration()
        TerminalSynchronizedOutput.write(
            "\u{1B}[s status \u{1B}[u", output: pipe.fileHandleForWriting, sink: nil,
            restoration: restoration)
        TerminalSynchronizedOutput.write(
            "second", output: pipe.fileHandleForWriting, sink: nil, restoration: restoration)
        let written = try Self.drain(pipe)

        #expect(written == Self.begin + "\u{1B}[s status \u{1B}[u" + Self.end
            + Self.begin + "second" + Self.end)
        #expect(written.components(separatedBy: Self.begin).count - 1 == 2)
        #expect(written.components(separatedBy: Self.end).count - 1 == 2)
    }

    @Test("An empty production write emits neither text nor markers")
    func emptyTextWritesNothing() throws {
        let pipe = Pipe()
        TerminalSynchronizedOutput.write(
            "", output: pipe.fileHandleForWriting, sink: nil, restoration: Self.isolatedRestoration())
        #expect(try Self.drain(pipe).isEmpty)
    }

    @Test("A production write without a terminal is a no-op")
    func missingOutputWritesNothing() {
        TerminalSynchronizedOutput.write(
            "text", output: nil, sink: nil, restoration: Self.isolatedRestoration())
    }

    // MARK: - Injected sinks stay unwrapped

    @Test("An injected sink receives the text unchanged and without markers")
    func injectedSinkIsNotWrapped() throws {
        let capture = SynchronizedOutputCapture()
        let pipe = Pipe()
        TerminalSynchronizedOutput.write(
            "frame text", output: pipe.fileHandleForWriting, sink: { capture.append($0) },
            restoration: Self.isolatedRestoration())
        TerminalSynchronizedOutput.write(
            "", output: pipe.fileHandleForWriting, sink: { capture.append($0) },
            restoration: Self.isolatedRestoration())

        #expect(capture.writes == ["frame text"])
        // The sink replaces the file handle: nothing reaches the terminal.
        #expect(try Self.drain(pipe).isEmpty)
    }

    @Test("TerminalPrimaryScreen with an injected sink never emits the markers")
    func primaryScreenWithSinkHasNoMarkers() {
        let capture = SynchronizedOutputCapture()
        let screen = TerminalPrimaryScreen(
            reports: TerminalCursorReport(), resizeGeneration: { 0 },
            output: { capture.append($0) })
        screen.commitFooter(
            geometry: TerminalPrimaryScreen.Geometry(rows: 24, columns: 80),
            reservedRows: 2,
            sequence: "\u{1B}[23;1H\u{1B}[2KPROMPT\u{1B}[24;1H\u{1B}[2KSTATUS")
        screen.append("hello world\r\n")

        #expect(!capture.writes.isEmpty)
        #expect(capture.writes.allSatisfy { !$0.contains(Self.marker) })
    }

    @Test("TerminalStatusBar with an injected sink never emits the markers")
    func statusBarWithSinkHasNoMarkers() async {
        let capture = SynchronizedOutputCapture()
        let bar = TerminalStatusBar(isEnabled: true) { capture.append($0) }

        let started = await bar.start()
        await bar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "mode", helpText: "help")
        await bar.stop()

        #expect(started)
        #expect(!capture.writes.isEmpty)
        #expect(capture.writes.allSatisfy { !$0.contains(Self.marker) })
    }

    // MARK: - Restoration

    @Test("The reset sequence ends the frame first, only when one is in flight")
    func resetSequenceReportsFrameInFlight() {
        typealias R = TerminalSignalRestoration
        #expect(R.synchronizedOutputReset == "\u{1B}[?2026l")
        #expect(R.resetSequence(for: .init(synchronizedOutput: true))
            == "\u{1B}[?2026l\u{1B}[?7h\u{1B}[0m\u{1B}[?25h")
        #expect(R.resetSequence(for: .init(enhancedKeyboardProtocol: true, bracketedPaste: true, primaryScreen: true, synchronizedOutput: true))
            == "\u{1B}[?2026l\u{1B}[<u\u{1B}[>4;0m\u{1B}[?2004l\u{1B}[?6l\u{1B}[r\u{1B}[?7h\u{1B}[0m\u{1B}[999999;1H\r\n\u{1B}[?25h")
        // Default modes keep the pre-existing bytes.
        #expect(!R.resetSequence(for: .init()).contains(Self.marker))
        #expect(!R.resetSequence(for: .init(enhancedKeyboardProtocol: true, bracketedPaste: true, primaryScreen: true)).contains(Self.marker))
    }

    @Test("A frame in flight is visible in the current modes and cleared afterwards")
    func frameInFlightIsTracked() {
        let restoration = Self.isolatedRestoration()
        let owner = Owner()
        restoration.registerRawMode(owner: ObjectIdentifier(owner), inputFileDescriptor: -1,
                                    controlFileDescriptor: -1, originalAttributes: termios())
        #expect(restoration.currentModes?.synchronizedOutput == false)
        let inside = restoration.withSynchronizedFrame { restoration.currentModes?.synchronizedOutput }
        let nested = restoration.withSynchronizedFrame {
            restoration.withSynchronizedFrame { restoration.currentModes?.synchronizedOutput }
        }
        #expect(inside == true)
        #expect(nested == true)
        #expect(restoration.currentModes?.synchronizedOutput == false)
        restoration.unregisterRawMode(owner: ObjectIdentifier(owner))
        withExtendedLifetime(owner) {}
    }

    @Test("A terminating signal during a frame resets DECSET 2026; otherwise it does not")
    func signalDuringFrameResetsSynchronizedOutput() throws {
        func capturedReset(duringFrame: Bool) throws -> String {
            let pipe = Pipe()
            let handler = Mutex<(@Sendable (Int32) -> Void)?>(nil)
            let restoration = TerminalSignalRestoration(
                installHandlers: { onSignal in
                    handler.withLock { $0 = onSignal }
                    return {}
                },
                terminate: { _ in }
            )
            let owner = Owner()
            // A pipe is not a TTY: tcsetattr fails harmlessly.
            restoration.registerRawMode(owner: ObjectIdentifier(owner),
                                        inputFileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                                        controlFileDescriptor: pipe.fileHandleForWriting.fileDescriptor,
                                        originalAttributes: termios())
            let onSignal = try #require(handler.withLock { $0 })
            if duringFrame {
                restoration.withSynchronizedFrame { onSignal(SIGTERM) }
            } else {
                onSignal(SIGTERM)
            }
            restoration.unregisterRawMode(owner: ObjectIdentifier(owner))
            withExtendedLifetime(owner) {}
            return try Self.drain(pipe)
        }

        #expect(try capturedReset(duringFrame: true)
            == TerminalSignalRestoration.resetSequence(for: .init(synchronizedOutput: true)))
        #expect(try capturedReset(duringFrame: true).hasPrefix(Self.end))
        #expect(try capturedReset(duringFrame: false)
            == TerminalSignalRestoration.resetSequence(for: .init()))
    }
}
