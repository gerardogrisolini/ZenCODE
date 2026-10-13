//
//  TerminalModalSession.swift
//  ZenCODE
//

import Foundation

/// A blocking input owner publishes presentation snapshots; it never owns a
/// second screen or writes cursor/erase commands over the persistent footer.
final class TerminalModalSession {
    private let screen: TerminalPrimaryScreen
    private let ownsScreen: Bool
    private let id: UUID
    private let resizeSubscription: TerminalResizeCoordinator.Subscription
    private var resizeGeneration: UInt64
    private var isClosed = false

    var cancellationCheck: @Sendable () -> Bool { { [screen] in screen.isAppendOnly } }
    var isCancelled: Bool { screen.isAppendOnly }
    func accepted<Value>(_ value: Value) -> Value? {
        TerminalOutputSynchronization.withTransaction { screen.isAppendOnly ? nil : value }
    }

    init(screen injectedScreen: TerminalPrimaryScreen? = nil) {
        let resolvedScreen: TerminalPrimaryScreen
        let standalone: Bool
        if let active = injectedScreen ?? TerminalPrimaryScreen.active {
            resolvedScreen = active
            standalone = false
        } else {
            resolvedScreen = TerminalPrimaryScreen {
                TerminalOutputSynchronization.writeOverlay($0, to: AgentOutput.standardError)
            }
            standalone = true
            // Before/after an active chat session there is no owned primary
            // viewport to reconstruct. Keep the existing temporary alternate
            // overlay rather than erasing unknown shell/setup output.
            TerminalOutputSynchronization.writeOverlay(
                "\u{1B}[?1049h\u{1B}[r\u{1B}[2J\u{1B}[H\u{1B}[?25l",
                to: AgentOutput.standardError
            )
            let geometry = TerminalCheckboxMenu.terminalGeometry()
            resolvedScreen.resizeStandalone(.init(rows: geometry.rows, columns: geometry.columns))
        }
        screen = resolvedScreen
        ownsScreen = standalone
        resizeSubscription = TerminalResizeCoordinator.shared.subscribe()
        resizeGeneration = TerminalResizeCoordinator.shared.currentGeneration()
        id = resolvedScreen.beginModal()
    }

    func update(_ value: TerminalPrimaryScreen.Modal) {
        guard !isClosed else { return }
        let generation = TerminalResizeCoordinator.shared.currentGeneration()
        if ownsScreen, generation != resizeGeneration {
            let geometry = TerminalCheckboxMenu.terminalGeometry()
            screen.resizeStandalone(.init(rows: geometry.rows, columns: geometry.columns))
        }
        resizeGeneration = generation
        screen.updateModal(id, value: value)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        resizeSubscription.cancel()
        screen.endModal(id)
        if ownsScreen {
            screen.stop()
            TerminalOutputSynchronization.writeOverlay(
                "\u{1B}[?1049l\u{1B}[?25h", to: AgentOutput.standardError
            )
        }
    }

    deinit { close() }
}
