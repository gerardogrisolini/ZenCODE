//
//  TerminalSignalRestoration.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Synchronization

#if canImport(Darwin)
private typealias SignalDisposition = sig_t
#else
private typealias SignalDisposition = __sighandler_t
#endif

/// Restores the terminal when the process is terminated by SIGINT, SIGTERM or
/// SIGHUP while raw mode is active. Ctrl-C keeps its default meaning (ISIG is
/// left enabled): the handler only resets the terminal modes ZenCODE enabled,
/// restores the original termios and then re-raises the signal with its
/// default disposition so the parent shell still observes death by signal.
///
/// Handlers are installed only while a TTY raw mode registration exists and
/// are removed (restoring the previous dispositions) when it is released.
final class TerminalSignalRestoration: Sendable {
    /// Terminal modes that require an explicit reset.
    struct Modes: Equatable, Sendable {
        var enhancedKeyboardProtocol = false
        var bracketedPaste = false
        var primaryScreen = false
    }

    /// Pops the kitty keyboard flags and resets xterm modifyOtherKeys; byte
    /// identical to the normal raw-mode restore path.
    static let enhancedKeyboardProtocolReset = "\u{1B}[<u\u{1B}[>4;0m"
    static let bracketedPasteReset = "\u{1B}[?2004l"
    /// DECOM off, full-screen DECSTBM margins, DECAWM on, SGR reset. Both DECOM
    /// and DECSTBM home the cursor; callers must reposition afterwards.
    static let screenModesReset = "\u{1B}[?6l\u{1B}[r\u{1B}[?7h\u{1B}[0m"
    /// CUP clamps to the physical bottom row; LF there allocates a fresh line
    /// without erasing transcript history.
    static let bottomFreshLine = "\u{1B}[999999;1H\r\n"
    static let showCursor = "\u{1B}[?25h"

    /// Pure reset sequence for the given modes.
    ///
    /// With the primary screen active the scroll region/origin reset is
    /// followed by a move to a fresh bottom line (same bytes as the
    /// `TerminalPrimaryScreen.stop()` append-only fallback), so the shell prompt
    /// does not overwrite the transcript from the home position. Without it,
    /// only the cursor-neutral DECAWM/SGR/cursor-visibility resets are emitted.
    static func resetSequence(for modes: Modes) -> String {
        var sequence = ""
        if modes.enhancedKeyboardProtocol { sequence += enhancedKeyboardProtocolReset }
        if modes.bracketedPaste { sequence += bracketedPasteReset }
        if modes.primaryScreen {
            sequence += screenModesReset + bottomFreshLine
        } else {
            sequence += "\u{1B}[?7h\u{1B}[0m"
        }
        return sequence + showCursor
    }

    /// Installs the process signal handlers; returns the uninstall action.
    typealias HandlerInstaller = @Sendable (
        _ onSignal: @escaping @Sendable (Int32) -> Void
    ) -> @Sendable () -> Void

    private struct RawRegistration {
        var owner: ObjectIdentifier
        var inputFileDescriptor: Int32
        var controlFileDescriptor: Int32
        var originalAttributes: termios
        var enhancedKeyboardProtocol = false
        var bracketedPaste = false
    }

    private struct State {
        var raw: RawRegistration?
        var primaryScreenOwner: ObjectIdentifier?
        var uninstallHandlers: (@Sendable () -> Void)?
        var didRestore = false
    }

    static let shared = TerminalSignalRestoration()

    private let state = Mutex(State())
    private let installHandlers: HandlerInstaller
    private let terminate: @Sendable (Int32) -> Void

    init(
        installHandlers: @escaping HandlerInstaller = TerminalSignalRestoration.installDispatchHandlers,
        terminate: @escaping @Sendable (Int32) -> Void = TerminalSignalRestoration.terminateWithDefaultDisposition
    ) {
        self.installHandlers = installHandlers
        self.terminate = terminate
    }

    // MARK: - Registration

    /// Records an active TTY raw mode and installs the signal handlers.
    func registerRawMode(
        owner: ObjectIdentifier,
        inputFileDescriptor: Int32,
        controlFileDescriptor: Int32,
        originalAttributes: termios
    ) {
        state.withLock { state in
            state.raw = RawRegistration(
                owner: owner,
                inputFileDescriptor: inputFileDescriptor,
                controlFileDescriptor: controlFileDescriptor,
                originalAttributes: originalAttributes
            )
            state.didRestore = false
            if state.uninstallHandlers == nil {
                state.uninstallHandlers = installHandlers { [self] signal in
                    handleTerminatingSignal(signal)
                }
            }
        }
    }

    /// Updates the input modes requested by the current raw-mode owner.
    func updateRawModes(owner: ObjectIdentifier, enhancedKeyboardProtocol: Bool? = nil, bracketedPaste: Bool? = nil) {
        state.withLock { state in
            guard state.raw?.owner == owner else { return }
            if let enhancedKeyboardProtocol { state.raw?.enhancedKeyboardProtocol = enhancedKeyboardProtocol }
            if let bracketedPaste { state.raw?.bracketedPaste = bracketedPaste }
        }
    }

    /// Releases the raw-mode registration and removes the signal handlers,
    /// restoring the previous dispositions. No-op for a stale owner.
    func unregisterRawMode(owner: ObjectIdentifier) {
        let uninstall = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.raw?.owner == owner else { return nil }
            state.raw = nil
            defer { state.uninstallHandlers = nil }
            return state.uninstallHandlers
        }
        uninstall?()
    }

    func setPrimaryScreenActive(_ isActive: Bool, owner: ObjectIdentifier) {
        state.withLock { state in
            if isActive {
                state.primaryScreenOwner = owner
            } else if state.primaryScreenOwner == owner {
                state.primaryScreenOwner = nil
            }
        }
    }

    var hasInstalledHandlers: Bool { state.withLock { $0.uninstallHandlers != nil } }

    var currentModes: Modes? {
        state.withLock { state in
            guard let raw = state.raw else { return nil }
            return Modes(
                enhancedKeyboardProtocol: raw.enhancedKeyboardProtocol,
                bracketedPaste: raw.bracketedPaste,
                primaryScreen: state.primaryScreenOwner != nil
            )
        }
    }

    // MARK: - Signal handling

    func handleTerminatingSignal(_ signal: Int32) {
        restoreTerminalForTermination()
        terminate(signal)
    }

    /// Writes the reset sequence straight to the terminal fd and restores the
    /// original termios. Idempotent: only the first call after a registration
    /// performs any I/O. No actor hop: the process is about to die.
    func restoreTerminalForTermination() {
        let snapshot = state.withLock { state -> (RawRegistration, Modes)? in
            guard !state.didRestore, let raw = state.raw else { return nil }
            state.didRestore = true
            let modes = Modes(
                enhancedKeyboardProtocol: raw.enhancedKeyboardProtocol,
                bracketedPaste: raw.bracketedPaste,
                primaryScreen: state.primaryScreenOwner != nil
            )
            return (raw, modes)
        }
        guard let (raw, modes) = snapshot else { return }
        if raw.controlFileDescriptor >= 0 {
            Self.writeAll(Array(Self.resetSequence(for: modes).utf8), to: raw.controlFileDescriptor)
        }
        var attributes = raw.originalAttributes
        _ = TerminalRawInput.withSIGTTOUBlocked {
            tcsetattr(raw.inputFileDescriptor, TCSANOW, &attributes)
        }
    }

    /// `write(2)` loop handling EINTR and partial writes.
    static func writeAll(_ bytes: [UInt8], to fileDescriptor: Int32) {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fileDescriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    // MARK: - Process-level installation

    static let terminatingSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private final class InstalledHandlers: @unchecked Sendable {
        // Mutated only by `uninstall()`, which the registry calls once.
        private var entries: [(signal: Int32, previous: SignalDisposition?, source: any DispatchSourceSignal)]
        /// Entered once per source at installation and left by its cancel
        /// handler, which libdispatch runs only after the source is fully
        /// unregistered.
        private let cancellations: DispatchGroup

        init(
            entries: [(signal: Int32, previous: SignalDisposition?, source: any DispatchSourceSignal)],
            cancellations: DispatchGroup
        ) {
            self.entries = entries
            self.cancellations = cancellations
        }

        func uninstall() {
            #if os(Linux)
            // On Linux libdispatch installs its own `sigaction` handler when it
            // registers a signal source, asynchronously on its manager thread,
            // and never removes it. Restoring the disposition first could
            // therefore be overwritten by a registration that lands later,
            // leaving SIGINT/SIGTERM/SIGHUP swallowed after the TUI exits.
            // Cancel every source, wait until libdispatch has finished with
            // them, then restore the previous dispositions last.
            for entry in entries {
                entry.source.cancel()
            }
            if DispatchQueue.getSpecific(key: TerminalSignalRestoration.signalQueueKey) == nil {
                cancellations.wait()
            }
            for entry in entries {
                _ = signal(entry.signal, entry.previous)
            }
            #else
            for entry in entries {
                // Restore the disposition before cancelling the source so a
                // late signal follows the previous semantics instead of being
                // swallowed by a cancelled source.
                _ = signal(entry.signal, entry.previous)
                entry.source.cancel()
            }
            #endif
            entries.removeAll()
        }
    }

    private static let signalQueueKey = DispatchSpecificKey<Void>()
    private static let signalQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "zencode.terminal.signal-restoration")
        queue.setSpecific(key: signalQueueKey, value: ())
        return queue
    }()

    private static func dispositionValue(_ disposition: SignalDisposition?) -> Int {
        unsafeBitCast(disposition, to: Int.self)
    }

    /// `signal(sig, SIG_IGN)` + a `DispatchSourceSignal` per signal on a
    /// dedicated queue. Signals already ignored (e.g. SIGHUP under `nohup`)
    /// are left untouched so ZenCODE never turns an ignored signal fatal.
    /// On Linux libdispatch later replaces `SIG_IGN` with its own handler
    /// while a source is registered; delivery still goes only to the source.
    static func installDispatchHandlers(
        onSignal: @escaping @Sendable (Int32) -> Void
    ) -> @Sendable () -> Void {
        var entries: [(signal: Int32, previous: SignalDisposition?, source: any DispatchSourceSignal)] = []
        let cancellations = DispatchGroup()
        for signalNumber in terminatingSignals {
            let previous = signal(signalNumber, SIG_IGN)
            let previousValue = dispositionValue(previous)
            if previousValue == dispositionValue(SIG_ERR) { continue }
            if previousValue == dispositionValue(SIG_IGN) { continue }
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
            source.setEventHandler { onSignal(signalNumber) }
            cancellations.enter()
            source.setCancelHandler { cancellations.leave() }
            source.resume()
            entries.append((signalNumber, previous, source))
        }
        let installed = InstalledHandlers(entries: entries, cancellations: cancellations)
        return { installed.uninstall() }
    }

    /// Restores the default disposition, unblocks the signal for this thread
    /// and re-raises it so exit status and shell semantics stay those of the
    /// signal. `_exit` is a last resort if the signal did not terminate us.
    static func terminateWithDefaultDisposition(_ signalNumber: Int32) {
        _ = signal(signalNumber, SIG_DFL)
        var signalSet = sigset_t()
        sigemptyset(&signalSet)
        sigaddset(&signalSet, signalNumber)
        _ = pthread_sigmask(SIG_UNBLOCK, &signalSet, nil)
        raise(signalNumber)
        _exit(128 + signalNumber)
    }
}
