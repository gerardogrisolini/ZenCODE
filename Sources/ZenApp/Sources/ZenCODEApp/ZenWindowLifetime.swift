//
//  ZenWindowLifetime.swift
//  ZenApp
//
//  Ties the session of a window to the NSWindow that shows it: the session
//  opens once and closes when that window really closes (or after `/exit`),
//  never when SwiftUI only hides the content (a background tab, a minimized
//  or ordered-out window).
//

import AppKit
import Foundation
import Observation
import SwiftUI
import ZenAppSession

/// The session of one window, for the window's whole life.
///
/// ``open(runtime:workspace:)`` opens it once. ``attach(to:)`` observes
/// `NSWindow.willCloseNotification` of the hosting window: when it fires the
/// session is closed, and a session still opening is closed as soon as it
/// opens. The observer holds this object until the window closes, so the
/// session is closed even when SwiftUI tore the window's views down first.
@MainActor
@Observable
final class ZenWindowLifetime {
    /// The window's session, once open.
    private(set) var session: ZenWindowSession?
    /// Why the session could not open.
    private(set) var openFailure: String?
    /// The hosting window closed.
    @ObservationIgnored private(set) var isWindowClosed = false

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var closeObserver: (any NSObjectProtocol)?

    init() {}

    /// Opens the window's session on `workspace`, once; a failure is kept in
    /// ``openFailure``.
    func open(runtime: ZenAppRuntime, workspace: URL) {
        guard openTask == nil, !isWindowClosed else { return }
        openTask = Task { @MainActor in
            do {
                let opened = try await runtime.openWindow(workspace: workspace)
                guard !self.isWindowClosed else {
                    await opened.close()
                    return
                }
                self.session = opened
            } catch {
                guard !self.isWindowClosed else { return }
                self.openFailure = ZenWindowRoot.describe(error)
            }
        }
    }

    /// Observes the closing of `window`, the window that hosts the session.
    func attach(to window: NSWindow) {
        guard !isWindowClosed, window !== self.window else { return }
        stopObserving()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.windowWillClose()
            }
        }
    }

    /// The hosting window closes: the session closes, and one still opening
    /// closes when it opens.
    func windowWillClose() {
        guard !isWindowClosed else { return }
        isWindowClosed = true
        stopObserving()
        closeSession()
    }

    /// Closes the session (``ZenWindowSession/close()``); the window stays.
    func closeSession() {
        guard let session else { return }
        Task { await session.close() }
    }

    private func stopObserving() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
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
