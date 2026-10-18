//
//  TerminalSignalRestorationTests.swift
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

@Suite("TerminalSignalRestoration")
struct TerminalSignalRestorationTests {
    private final class Owner {}

    @Test("Reset sequence emits only the modes that were enabled")
    func resetSequenceFlags() {
        typealias R = TerminalSignalRestoration
        #expect(R.resetSequence(for: .init()) == "\u{1B}[?7h\u{1B}[0m\u{1B}[?25h")
        #expect(R.resetSequence(for: .init(enhancedKeyboardProtocol: true))
            == "\u{1B}[<u\u{1B}[>4;0m\u{1B}[?7h\u{1B}[0m\u{1B}[?25h")
        #expect(R.resetSequence(for: .init(bracketedPaste: true))
            == "\u{1B}[?2004l\u{1B}[?7h\u{1B}[0m\u{1B}[?25h")
        #expect(R.resetSequence(for: .init(primaryScreen: true))
            == "\u{1B}[?6l\u{1B}[r\u{1B}[?7h\u{1B}[0m\u{1B}[999999;1H\r\n\u{1B}[?25h")
        #expect(R.resetSequence(for: .init(enhancedKeyboardProtocol: true, bracketedPaste: true, primaryScreen: true))
            == "\u{1B}[<u\u{1B}[>4;0m\u{1B}[?2004l\u{1B}[?6l\u{1B}[r\u{1B}[?7h\u{1B}[0m\u{1B}[999999;1H\r\n\u{1B}[?25h")
    }

    @Test("Handlers are installed once per raw registration and removed by its owner only")
    func installUninstallCycle() {
        let installs = Mutex(0)
        let uninstalls = Mutex(0)
        let restoration = TerminalSignalRestoration(
            installHandlers: { _ in
                installs.withLock { $0 += 1 }
                return { uninstalls.withLock { $0 += 1 } }
            },
            terminate: { _ in Issue.record("terminate must not run") }
        )
        let owner = Owner(), stranger = Owner()
        #expect(!restoration.hasInstalledHandlers)
        #expect(restoration.currentModes == nil)

        restoration.registerRawMode(owner: ObjectIdentifier(owner), inputFileDescriptor: -1,
                                    controlFileDescriptor: -1, originalAttributes: termios())
        restoration.registerRawMode(owner: ObjectIdentifier(owner), inputFileDescriptor: -1,
                                    controlFileDescriptor: -1, originalAttributes: termios())
        #expect(installs.withLock { $0 } == 1)
        #expect(restoration.hasInstalledHandlers)

        restoration.updateRawModes(owner: ObjectIdentifier(owner), enhancedKeyboardProtocol: true, bracketedPaste: true)
        restoration.updateRawModes(owner: ObjectIdentifier(stranger), bracketedPaste: false)
        restoration.setPrimaryScreenActive(true, owner: ObjectIdentifier(stranger))
        #expect(restoration.currentModes == .init(enhancedKeyboardProtocol: true, bracketedPaste: true, primaryScreen: true))
        restoration.setPrimaryScreenActive(false, owner: ObjectIdentifier(owner))
        #expect(restoration.currentModes?.primaryScreen == true)
        restoration.setPrimaryScreenActive(false, owner: ObjectIdentifier(stranger))
        #expect(restoration.currentModes?.primaryScreen == false)

        restoration.unregisterRawMode(owner: ObjectIdentifier(stranger))
        #expect(uninstalls.withLock { $0 } == 0)
        restoration.unregisterRawMode(owner: ObjectIdentifier(owner))
        restoration.unregisterRawMode(owner: ObjectIdentifier(owner))
        #expect(uninstalls.withLock { $0 } == 1)
        #expect(!restoration.hasInstalledHandlers)
        #expect(restoration.currentModes == nil)
        withExtendedLifetime((owner, stranger)) {}
    }

    @Test("Signal handling writes the reset once to the control fd, then terminates")
    func signalHandlingWritesResetOnce() throws {
        let pipe = Pipe()
        let terminated = Mutex<[Int32]>([])
        let handler = Mutex<(@Sendable (Int32) -> Void)?>(nil)
        let restoration = TerminalSignalRestoration(
            installHandlers: { onSignal in
                handler.withLock { $0 = onSignal }
                return {}
            },
            terminate: { signal in terminated.withLock { $0.append(signal) } }
        )
        let owner = Owner()
        // A pipe is not a TTY: tcsetattr fails harmlessly, no real terminal is touched.
        restoration.registerRawMode(owner: ObjectIdentifier(owner),
                                    inputFileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                                    controlFileDescriptor: pipe.fileHandleForWriting.fileDescriptor,
                                    originalAttributes: termios())
        restoration.updateRawModes(owner: ObjectIdentifier(owner), enhancedKeyboardProtocol: true, bracketedPaste: true)
        restoration.setPrimaryScreenActive(true, owner: ObjectIdentifier(owner))

        let onSignal = try #require(handler.withLock { $0 })
        onSignal(SIGTERM)
        onSignal(SIGINT)
        try pipe.fileHandleForWriting.close()
        let written = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(written == TerminalSignalRestoration.resetSequence(
            for: .init(enhancedKeyboardProtocol: true, bracketedPaste: true, primaryScreen: true)))
        #expect(terminated.withLock { $0 } == [SIGTERM, SIGINT])
        restoration.setPrimaryScreenActive(false, owner: ObjectIdentifier(owner))
        restoration.unregisterRawMode(owner: ObjectIdentifier(owner))
    }

    @Test("Dispatch installer ignores the signals while armed and restores previous dispositions")
    func dispatchInstallerRestoresDispositions() {
        let signals = TerminalSignalRestoration.terminatingSignals
        let before = signals.map(Self.dispositionValue)
        let uninstall = TerminalSignalRestoration.installDispatchHandlers { _ in
            Issue.record("no signal is sent by this test")
        }
        let ignored = Self.ignoredValue
        // Previously ignored signals stay ignored; all others are now SIG_IGN
        // with delivery routed through the dispatch source.
        #expect(signals.map(Self.dispositionValue).allSatisfy { $0 == ignored })
        uninstall()
        #expect(signals.map(Self.dispositionValue) == before)
    }

    private static var ignoredValue: Int { unsafeBitCast(SIG_IGN, to: Int.self) }

    /// Reads the current disposition without changing it.
    private static func dispositionValue(_ signalNumber: Int32) -> Int {
        var action = sigaction()
        _ = sigaction(signalNumber, nil, &action)
        #if canImport(Darwin)
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
        #else
        return unsafeBitCast(action.__sigaction_handler.sa_handler, to: Int.self)
        #endif
    }
}
