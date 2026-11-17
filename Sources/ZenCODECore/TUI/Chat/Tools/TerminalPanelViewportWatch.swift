//
//  TerminalPanelViewportWatch.swift
//  ZenCODE
//
//  The viewport checks the full-screen panels (`/subagent`, `/artifacts`)
//  share: a poll and the resize signals compare the viewport with the last
//  frame's, so the panel draws again for a new geometry and closes once the
//  screen fell back to append-only output.
//

import Foundation

/// The viewport checks of a full-screen panel controller.
///
/// The primary screen commits a new geometry, and possibly a new footer
/// height, only after the resize signal, so a light task compares the
/// viewport every `pollInterval` and asks the panel to draw again when it
/// changed; a resize signal triggers the same check at once. The check calls
/// `layoutUnavailable` once the screen fell back to append-only output
/// (`isCancelled`).
@ChatSessionActor
final class TerminalPanelViewportWatch {
    /// The rows and columns a frame is drawn for.
    struct Viewport: Equatable {
        let rows: Int
        let columns: Int

        init(_ viewport: (rows: Int, columns: Int)) {
            rows = viewport.rows
            columns = viewport.columns
        }
    }

    private let viewport: @ChatSessionActor () -> (rows: Int, columns: Int)
    private let isCancelled: @ChatSessionActor () -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pollInterval: Duration
    private let subscribeResize: (_ observer: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
    private var pollTask: Task<Void, Never>?
    private var cancelResizeSubscription: (@Sendable () -> Void)?
    /// The viewport of the last frame presented.
    private var lastViewport: Viewport?

    /// - Parameters:
    ///   - viewport: The rows and columns of the panel's frame, read at every
    ///     frame and check.
    ///   - isCancelled: Whether the screen fell back to append-only output.
    ///   - sleep: Waits for a duration; throws when its task is cancelled.
    ///   - pollInterval: How often the viewport is compared with the last
    ///     frame's.
    ///   - subscribeResize: Subscribes an observer to the terminal resize
    ///     signals and returns the cancellation of the subscription.
    init(
        viewport: @escaping @ChatSessionActor () -> (rows: Int, columns: Int),
        isCancelled: @escaping @ChatSessionActor () -> Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        pollInterval: Duration,
        subscribeResize: @escaping (_ observer: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
    ) {
        self.viewport = viewport
        self.isCancelled = isCancelled
        self.sleep = sleep
        self.pollInterval = pollInterval
        self.subscribeResize = subscribeResize
    }

    /// The production `subscribeResize`: a
    /// ``TerminalResizeCoordinator/shared`` subscription.
    nonisolated static func subscribeToTerminalResize(
        _ observer: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        let subscription = TerminalResizeCoordinator.shared.subscribe(observer)
        return { subscription.cancel() }
    }

    /// The viewport of the moment, recorded as the one of the frame about to
    /// be presented.
    func frameViewport() -> Viewport {
        let frame = Viewport(viewport())
        lastViewport = frame
        return frame
    }

    /// Starts the checks: a poll every `pollInterval` and one at every resize
    /// signal. Each check does nothing once `isActive` is `false`, calls
    /// `layoutUnavailable` when the screen fell back to append-only output,
    /// and otherwise calls `redraw` when the viewport changed since the last
    /// frame. A second call while the checks run does nothing.
    func start(
        isActive: @escaping @ChatSessionActor () -> Bool,
        layoutUnavailable: @escaping @ChatSessionActor () async -> Void,
        redraw: @escaping @ChatSessionActor () -> Void
    ) {
        guard pollTask == nil, cancelResizeSubscription == nil else { return }
        let check: @ChatSessionActor () async -> Void = { [weak self] in
            await self?.checkLayout(
                isActive: isActive,
                layoutUnavailable: layoutUnavailable,
                redraw: redraw
            )
        }
        cancelResizeSubscription = subscribeResize {
            Task { @ChatSessionActor in
                await check()
            }
        }
        let sleep = sleep
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard let self, isActive() else { return }
                if self.isCancelled() {
                    // This check closes the panel: keep it out of the
                    // cancellation of `stop()`, so the close runs uncancelled.
                    self.pollTask = nil
                }
                await check()
                guard isActive() else { return }
            }
        }
    }

    /// Cancels the poll and the resize subscription. Idempotent.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        cancelResizeSubscription?()
        cancelResizeSubscription = nil
    }

    private func checkLayout(
        isActive: @ChatSessionActor () -> Bool,
        layoutUnavailable: @ChatSessionActor () async -> Void,
        redraw: @ChatSessionActor () -> Void
    ) async {
        guard isActive() else { return }
        guard !isCancelled() else {
            await layoutUnavailable()
            return
        }
        guard Viewport(viewport()) != lastViewport else { return }
        redraw()
    }
}
