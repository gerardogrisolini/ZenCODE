//
//  TerminalResizeCoordinator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization

/// Process-wide SIGWINCH ownership shared by the status bar and blocking
/// terminal overlays. Consumers poll the generation from their blocking loop;
/// the status bar also receives a notification so it can publish its layout.
final class TerminalResizeCoordinator: @unchecked Sendable {
    static let shared = TerminalResizeCoordinator()

    private final class SourceBox: @unchecked Sendable {
        let source: any DispatchSourceSignal

        init(source: any DispatchSourceSignal) {
            self.source = source
        }
    }

    private struct State: @unchecked Sendable {
        var generation: UInt64 = 0
        var physicalGeneration: UInt64 = 0
        var publishedReservedRows: Int?
        var source: SourceBox?
        var observers: [UUID: @Sendable () -> Void] = [:]
    }

    /// Keeps the broker alive while a status bar or blocking menu/prompt is
    /// using the terminal. Cancellation is idempotent and safe from any queue.
    final class Subscription: @unchecked Sendable {
        private weak var owner: TerminalResizeCoordinator?
        private let id: UUID
        private let cancellation = Mutex(false)

        fileprivate init(owner: TerminalResizeCoordinator, id: UUID) {
            self.owner = owner
            self.id = id
        }

        func cancel() {
            let shouldCancel = cancellation.withLock { cancelled in
                guard !cancelled else { return false }
                cancelled = true
                return true
            }
            guard shouldCancel else { return }
            owner?.removeObserver(id: id)
        }

        deinit {
            cancel()
        }
    }

    private let state = Mutex(State())

    func subscribe(_ observer: @escaping @Sendable () -> Void = {}) -> Subscription {
        let id = UUID()
        var sourceToResume: (any DispatchSourceSignal)?
        state.withLock { state in
            state.observers[id] = observer
            guard state.source == nil else { return }

            signal(SIGWINCH, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: SIGWINCH,
                queue: .global(qos: .userInteractive)
            )
            source.setEventHandler { [weak self] in
                self?.publishResizeSignal()
            }
            state.source = SourceBox(source: source)
            sourceToResume = source
        }
        sourceToResume?.resume()
        return Subscription(owner: self, id: id)
    }

    func currentGeneration() -> UInt64 {
        state.withLock { $0.generation }
    }

    func physicalGeneration() -> UInt64 { state.withLock { $0.physicalGeneration } }

    /// Requests observers to repaint after an overlay restores the primary
    /// screen. Unlike SIGWINCH this does not install or emit a signal; it only
    /// advances the generation and invokes the currently subscribed observers.
    func requestRefresh() {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            state.generation &+= 1
            return Array(state.observers.values)
        }
        observers.forEach { $0() }
    }

    /// Returns the latest status-bar reservation when one is available, while
    /// preserving the caller's initial reservation for standalone overlays.
    func reservedBottomRows(fallback: Int) -> Int {
        state.withLock { $0.publishedReservedRows ?? max(0, fallback) }
    }

    /// Called by the status bar after it has committed the new terminal
    /// geometry. Publishing a layout advances the same generation so an open
    /// blocking overlay repaints once more after the status-bar reservation is
    /// current, without causing another SIGWINCH scheduling cycle.
    func publishLayout(reservedBottomRows: Int?) {
        state.withLock { state in
            state.generation &+= 1
            state.publishedReservedRows = reservedBottomRows.map { max(0, $0) }
        }
    }

    private func publishResizeSignal() {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            state.generation &+= 1
            state.physicalGeneration &+= 1
            return Array(state.observers.values)
        }
        observers.forEach { $0() }
    }

    private func removeObserver(id: UUID) {
        var sourceToCancel: (any DispatchSourceSignal)?
        state.withLock { state in
            state.observers.removeValue(forKey: id)
            guard state.observers.isEmpty, let source = state.source else { return }
            state.source = nil
            sourceToCancel = source.source
        }
        guard let sourceToCancel else { return }
        sourceToCancel.setEventHandler {}
        sourceToCancel.cancel()
    }
}
