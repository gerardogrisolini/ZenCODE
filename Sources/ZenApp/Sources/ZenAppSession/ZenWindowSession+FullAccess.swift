//
//  ZenWindowSession+FullAccess.swift
//  ZenApp
//
//  The app's access mode as a window shows and switches it.
//

import Foundation
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Full access

    /// The app's runner runs `local.exec` and the destructive direct tools
    /// without asking for consent (``ZenAppRuntime/localExecAccessMode``).
    public var isFullAccess: Bool {
        runtime?.localExecAccessMode == .fullAccess
    }

    /// Switches the app's access mode, for every window, as the terminal's
    /// Ctrl+G does (``ZenAppRuntime/toggleLocalExecAccessMode()``); also
    /// while a turn runs. Refused while Telegram drives the slot: the session
    /// the chat drives keeps its access mode. Does nothing once the window
    /// closed.
    public func toggleFullAccess() {
        guard !isClosed else { return }
        guard !refusedWhileDormant() else { return }
        runtime?.toggleLocalExecAccessMode()
    }

    /// The runtime's access mode changed to `mode`: the status bar shows it
    /// and the transcript gets the terminal's message.
    func localExecAccessModeDidChange(_ mode: AgentLocalExecAccessMode) {
        guard !isClosed else { return }
        adoptLocalExecAccessMode(mode)
        appendLocalNow(.local(
            text: ChatSessionNoticeText.localExecAccessModeChangeText(mode),
            isFailure: false
        ))
    }

    /// Shows `mode` in the status bar, without a message row.
    func adoptLocalExecAccessMode(_ mode: AgentLocalExecAccessMode) {
        guard !isClosed, status.localExecAccessMode != mode else { return }
        status.localExecAccessMode = mode
    }
}
