//
//  ZenAppDelegate.swift
//  ZenApp
//
//  The application delegate: makes the bundle-less SwiftPM executable a
//  regular app with the ZenCODE icon, starts the runtime, and shuts it down
//  before the app quits.
//

import AppKit
import Foundation
import ZenAppSession

/// The application delegate of ``ZenCODEApp``.
@MainActor
final class ZenAppDelegate: NSObject, NSApplicationDelegate {
    /// What a quit request runs: the launcher's termination step and
    /// shutdown, the reply to a deferred request, and the request to ask how
    /// to close the worktree. Tests replace them.
    struct Termination {
        var step: @MainActor () -> ZenAppLauncher.TerminationStep
        var shutdown: @MainActor () async -> Void
        var reply: @MainActor () -> Void
        var requestWorktreeClosure: @MainActor () -> Void

        init(
            step: @escaping @MainActor () -> ZenAppLauncher.TerminationStep,
            shutdown: @escaping @MainActor () async -> Void,
            reply: @escaping @MainActor () -> Void,
            requestWorktreeClosure: @escaping @MainActor () -> Void
        ) {
            self.step = step
            self.shutdown = shutdown
            self.reply = reply
            self.requestWorktreeClosure = requestWorktreeClosure
        }

        /// The launcher's step and shutdown; the reply lets the app quit; the
        /// request opens the Worktree window (``ZenWorktreeClosure/request()``).
        init(launcher: ZenAppLauncher) {
            self.init(
                step: { launcher.terminationStep() },
                shutdown: { await launcher.shutdown() },
                reply: { NSApp.reply(toApplicationShouldTerminate: true) },
                requestWorktreeClosure: { launcher.readyRuntime?.worktreeClosure?.request() }
            )
        }
    }

    /// The runtime of the app, shared by every window.
    let launcher = ZenAppLauncher()
    /// What a quit request runs.
    lazy var termination = Termination(launcher: launcher)
    /// Answers the quit request that waits for the shutdown. Set before the
    /// first request is deferred, so a later request never starts a second
    /// one.
    private(set) var terminationGate: ZenTerminationGate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable has no bundle: without the regular policy it
        // gets no Dock icon, no menu bar and no key window.
        NSApp.setActivationPolicy(.regular)
        // The executable has no bundle icon either: draw the ZenCODE one for
        // the Dock and ⌘Tab. If the symbol is missing, keep the default icon.
        if let symbol = ZenAppIcon.loadSymbol() {
            NSApp.applicationIconImage = ZenAppIcon.tile(symbol: symbol)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        launcher.start()
    }

    /// The app quits with its last window, except while the worktree of a
    /// `--worktree` launch waits for the operator's choice: the Worktree
    /// window asks it, and the choice quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        launcher.readyRuntime?.worktreeClosure?.isPending != true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Waits for the runtime to shut down (and for a launch still in
    /// progress) before the app quits, for at most
    /// ``ZenAppLauncher/terminationTimeout``: the app quits when the shutdown
    /// ends or when the timeout passes, whichever comes first, with one reply.
    /// A request that arrives while the gate waits, even before its shutdown
    /// task started, is cancelled: the gate replies for the first one.
    ///
    /// With the worktree of a `--worktree` launch still to close, the request
    /// is cancelled and the Worktree window opens instead: the operator's
    /// choice shuts the runtime down and quits. While the chosen action runs,
    /// a request is cancelled too: the Worktree window quits when it ends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationGate == nil else {
            return .terminateCancel
        }
        let termination = termination
        switch termination.step() {
        case .terminateNow:
            return .terminateNow
        case .askWorktreeClosure:
            termination.requestWorktreeClosure()
            return .terminateCancel
        case .alreadyShuttingDown:
            // The pending shutdown replies for the first request, or the
            // Worktree window quits once its closing ends.
            return .terminateCancel
        case .shutDownFirst:
            let gate = ZenTerminationGate { _ in
                termination.reply()
            }
            terminationGate = gate
            gate.start(timeout: ZenAppLauncher.terminationTimeout) {
                await termination.shutdown()
            }
            return .terminateLater
        }
    }
}
