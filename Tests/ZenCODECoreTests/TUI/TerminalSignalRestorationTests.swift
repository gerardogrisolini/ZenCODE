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

/// Not serialized: the two tests that install the real dispatch handlers
/// mutate the process-wide dispositions of SIGINT/SIGTERM/SIGHUP (`SIG_IGN`,
/// which a child spawned meanwhile by another suite would inherit), so they run
/// in a child process (exit tests) and this process never touches the signals.
/// The other tests inject the installer and share no state.
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
    func dispatchInstallerRestoresDispositions() async {
        await #expect(processExitsWith: .success) {
            let signals = TerminalSignalRestoration.terminatingSignals
            let before = signals.map(TerminalSignalRestorationTests.dispositionValue)
            let uninstall = TerminalSignalRestoration.installDispatchHandlers { _ in
                TerminalSignalRestorationTests.exitReporting(["a signal arrived: none is sent by this test"])
            }
            var problems = TerminalSignalRestorationTests.armedProblems(signals: signals, before: before)
            uninstall()
            if signals.map(TerminalSignalRestorationTests.dispositionValue) != before {
                problems.append("the dispositions were not restored by the uninstall")
            }
            TerminalSignalRestorationTests.exitReporting(problems)
        }
    }

    /// On Linux libdispatch replaces `SIG_IGN` with its own handler some time
    /// after the source is resumed and never removes it. Uninstalling after
    /// that replacement must still restore the previous dispositions.
    @Test("Dispatch installer restores dispositions after libdispatch registered its handler")
    func dispatchInstallerRestoresAfterLateRegistration() async {
        await #expect(processExitsWith: .success) {
            let signals = TerminalSignalRestoration.terminatingSignals
            let before = signals.map(TerminalSignalRestorationTests.dispositionValue)
            let uninstall = TerminalSignalRestoration.installDispatchHandlers { _ in
                TerminalSignalRestorationTests.exitReporting(["a signal arrived: none is sent by this test"])
            }
            // Give libdispatch's manager thread time to register the sources.
            try? await Task.sleep(for: .milliseconds(200))
            var problems = TerminalSignalRestorationTests.armedProblems(signals: signals, before: before)
            uninstall()
            if signals.map(TerminalSignalRestorationTests.dispositionValue) != before {
                problems.append("the dispositions were not restored by the uninstall")
            }
            TerminalSignalRestorationTests.exitReporting(problems)
        }
    }

    /// Ends the child process of an exit test: with status 0 when `problems`
    /// is empty, otherwise naming each one on standard error first. `#expect`
    /// is not used in the child, whose issues the parent would not see.
    private static func exitReporting(_ problems: [String]) -> Never {
        for problem in problems {
            FileHandle.standardError.write(Data((problem + "\n").utf8))
        }
        exit(problems.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    /// Previously ignored signals stay ignored. The others are `SIG_IGN` with
    /// delivery routed through the dispatch source; on Linux libdispatch may
    /// already have replaced `SIG_IGN` with its own handler, which still never
    /// applies the default (terminating) action.
    private static func armedProblems(signals: [Int32], before: [Int]) -> [String] {
        let ignored = ignoredValue
        var problems: [String] = []
        for (signalNumber, previous) in zip(signals, before) {
            let current = dispositionValue(signalNumber)
            if previous == ignored {
                if current != ignored { problems.append("signal \(signalNumber) must stay ignored") }
                continue
            }
            #if os(Linux)
            if current == defaultValue {
                problems.append("signal \(signalNumber) must not use its default action while armed")
            }
            #else
            if current != ignored { problems.append("signal \(signalNumber) must be SIG_IGN while armed") }
            #endif
        }
        return problems
    }

    private static var ignoredValue: Int { unsafeBitCast(SIG_IGN, to: Int.self) }
    private static var defaultValue: Int { unsafeBitCast(SIG_DFL, to: Int.self) }

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
