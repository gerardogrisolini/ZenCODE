//
//  ZenWindowLifetime.swift
//  ZenApp
//
//  Ties the sessions of a window to the NSWindow that shows them: they open
//  once and close when that window really closes, never when SwiftUI only
//  hides the content (a background tab, a minimized or ordered-out window).
//  It also tells the runtime when that window becomes the key one, so the
//  app's voice mode follows its selected session.
//

import AppKit
import Foundation
import Observation
import SwiftUI
import ZenAppSession

/// The sessions of one system window, for the window's whole life.
///
/// ``open(runtime:workspace:)`` opens their ``ZenWorkspaceWindow`` and its
/// first session once. ``attach(to:)`` observes
/// `NSWindow.willCloseNotification` of the hosting window: when it fires every
/// session is closed, and one still opening is closed as soon as it opens. The
/// observer holds this object until the window closes, so the sessions are
/// closed even when SwiftUI tore the window's views down first.
///
/// It also observes `NSWindow.didBecomeKeyNotification` of the same window:
/// whenever the window becomes the key one, changes its selected session, or
/// opens its first session while already key, the runtime hears of it
/// (``ZenAppRuntime/windowDidBecomeActive(_:)``), so voice mode follows the
/// session the operator works in. The notification of the hosting NSWindow,
/// rather than SwiftUI's active state, says exactly when this window became
/// key, whether a click, the Window menu, or a window tab brought it forward,
/// and keeps firing while SwiftUI hides the content; a sheet or a panel that
/// takes the key status moves voice mode nowhere.
@MainActor
@Observable
final class ZenWindowLifetime {
    /// The window's session container, once opening starts.
    private(set) var workspaceWindow: ZenWorkspaceWindow?
    /// The session shown by the window.
    var session: ZenWindowSession? { workspaceWindow?.selectedSession }
    /// Why the first session could not open.
    var openFailure: String? { workspaceWindow?.openFailure }
    /// The hosting window closed.
    @ObservationIgnored private(set) var isWindowClosed = false
    /// Runs first when the hosting window closes, once, before the sessions
    /// close.
    @ObservationIgnored var onWindowWillClose: (@MainActor () -> Void)?

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var closeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var keyObserver: (any NSObjectProtocol)?
    /// The runtime the sessions opened in, told when the window becomes key.
    @ObservationIgnored private var runtime: ZenAppRuntime?

    init() {}

    /// Opens the window's first session on `workspace`, once. A failure is
    /// kept by ``ZenWorkspaceWindow/openFailure``.
    func open(runtime: ZenAppRuntime, workspace: URL) {
        guard openTask == nil, !isWindowClosed else { return }
        self.runtime = runtime
        let workspaceWindow = ZenWorkspaceWindow(runtime: runtime, workspace: workspace)
        self.workspaceWindow = workspaceWindow
        runtime.registerWorkspaceWindow(workspaceWindow)
        workspaceWindow.sessionDidJoin = { [weak self] session in
            self?.installFocusAction(of: session)
        }
        workspaceWindow.selectionDidChange = { [weak self] _ in
            self?.windowDidBecomeKey()
        }
        openTask = Task { @MainActor in
            await workspaceWindow.openFirstSession()
            // The window may have become key before its session opened, as
            // the first window at launch usually does.
            if self.window?.isKeyWindow == true {
                self.windowDidBecomeKey()
            }
        }
    }

    /// Observes the closing of `window`, the window that hosts the sessions,
    /// and when it becomes the key one.
    func attach(to window: NSWindow) {
        guard !isWindowClosed, window !== self.window else { return }
        stopObserving()
        self.window = window
        for session in workspaceWindow?.sessions ?? [] {
            installFocusAction(of: session)
        }
        if let pending = workspaceWindow?.pendingWorktreeFocus {
            workspaceWindow?.pendingWorktreeFocus = nil
            runtime?.focusWindow(pending)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.windowWillClose()
            }
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.windowDidBecomeKey()
            }
        }
        if window.isKeyWindow {
            windowDidBecomeKey()
        }
    }

    /// The hosting window became the key one or changed its selection: voice
    /// mode follows its selected session from now on. Nothing before the
    /// first session opened and once the window closed.
    func windowDidBecomeKey() {
        guard !isWindowClosed, window?.isKeyWindow == true,
              let session, let runtime else { return }
        runtime.windowDidBecomeActive(session)
    }

    /// The hosting window closes: ``onWindowWillClose`` runs, then every
    /// session closes, and one still opening closes when it opens.
    func windowWillClose() {
        guard !isWindowClosed else { return }
        isWindowClosed = true
        workspaceWindow?.beginSystemWindowClose()
        onWindowWillClose?()
        stopObserving()
        closeSessions()
    }

    /// Closes every session (``ZenWorkspaceWindow/close()``); the system
    /// window is already closing.
    func closeSessions() {
        guard let workspaceWindow else { return }
        Task { await workspaceWindow.close() }
    }

    /// Selects `session` in its workspace window and brings the native window
    /// or tab forward.
    private func installFocusAction(of session: ZenWindowSession) {
        guard !session.isClosed, window != nil else { return }
        session.bringToFront = { [weak self, weak session] in
            guard let self, let session, let window = self.window, !session.isClosed else { return }
            self.workspaceWindow?.select(session)
            // A minimized tab group's visible window may not be this tab.
            if let selected = window.tabGroup?.selectedWindow, selected.isMiniaturized {
                selected.deminiaturize(nil)
            }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func stopObserving() {
        for session in workspaceWindow?.sessions ?? [] {
            session.bringToFront = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
        closeObserver = nil
        keyObserver = nil
        window = nil
    }
}

/// Hands the window that hosts it to `onWindow`, each time it moves into
/// one. It draws nothing and takes no clicks.
struct ZenWindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ZenWindowAccessorView {
        let view = ZenWindowAccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ZenWindowAccessorView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window {
            onWindow(window)
        }
    }
}

/// The view of ``ZenWindowAccessor``.
final class ZenWindowAccessorView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
