//
//  ZenWorkspaceWindow.swift
//  ZenApp
//
//  One system window of the app on a workspace: the sessions it hosts, each
//  one a slot of its own that works in parallel with the others, and the one
//  it shows.
//

import Foundation
import Observation
import ZenCODECore

/// The sessions of one system window, all on ``workspace``, in the order they
/// opened (``sessions``), and the one the window shows (``selectedSession``).
///
/// Each session is a ``ZenWindowSession``: a slot of the host on a runner of
/// its own, so its model, agent, and thinking level are its own, and it
/// generates, waits for an answer, or is driven from Telegram while the
/// operator works in another session of the window. New Session
/// (``openNewSession()``) adds a session to this window, with the selection
/// of the selected one, and selects it; it never opens another system window.
///
/// `/exit` in a session closes that session alone (``closeSession(_:)``);
/// once the last session closed, the window asks to close
/// (``closeRequested``). When the system window closes, ``close()`` closes
/// every session, also one still opening.
@MainActor
@Observable
public final class ZenWorkspaceWindow {
    /// The working directory of every session of the window.
    public let workspace: URL
    /// The open sessions of the window, in the order they opened.
    public private(set) var sessions: [ZenWindowSession] = []
    /// The session the window shows; `nil` before the first one opened, and
    /// once none is left.
    public private(set) var selectedSession: ZenWindowSession?
    /// A session of the window is opening (``openFirstSession()``,
    /// ``openNewSession()``).
    public private(set) var isOpeningSession = false
    /// Why the first session of the window could not open; `nil` otherwise.
    /// A later session that cannot open shows its failure as a row of the
    /// selected session instead.
    public private(set) var openFailure: String?
    /// The last session of the window closed (`/exit`, ``closeSession(_:)``):
    /// the shell closes the window. ``close()`` does not set it.
    public private(set) var closeRequested = false

    /// Runs when a session joins the window, before it is selected: the
    /// shell gives it the focus action of the system window
    /// (``ZenWindowSession/bringToFront``).
    @ObservationIgnored public var sessionDidJoin: (@MainActor (ZenWindowSession) -> Void)?
    /// Runs when ``selectedSession`` changes, with the new selection: the
    /// shell tells the runtime when the window is the key one
    /// (``ZenAppRuntime/windowDidBecomeActive(_:)``).
    @ObservationIgnored public var selectionDidChange: (@MainActor (ZenWindowSession?) -> Void)?

    @ObservationIgnored private let runtime: ZenAppRuntime
    /// ``openFirstSession()`` ran.
    @ObservationIgnored private var didOpenFirstSession = false
    /// ``close()`` ran.
    @ObservationIgnored public private(set) var isClosed = false
    /// The sessions still opening.
    @ObservationIgnored private var openingCount = 0
    /// ``close()`` waits here for the sessions still opening.
    @ObservationIgnored private var openingsDidEnd: [CheckedContinuation<Void, Never>] = []

    public init(runtime: ZenAppRuntime, workspace: URL) {
        self.runtime = runtime
        self.workspace = workspace
    }

    // MARK: - Opening

    /// Opens the first session of the window, with the launch profile, and
    /// selects it; a failure is kept in ``openFailure``. Only the first call
    /// does anything.
    public func openFirstSession() async {
        guard !didOpenFirstSession, !isClosed else { return }
        didOpenFirstSession = true
        beginOpening()
        defer { endOpening() }
        do {
            let session = try await runtime.openWindow(workspace: workspace)
            guard !isClosed else {
                await session.close()
                return
            }
            add(session, selecting: selectedSession == nil)
        } catch {
            guard !isClosed else { return }
            openFailure = Self.describe(error)
        }
    }

    /// Opens a new session in this window, with the selection (model, agent,
    /// thinking level) of the selected session
    /// (``ZenAppRuntime/openWindow(workspace:inheritingSelectionFrom:)``),
    /// adds it after the others, and selects it. It opens also while other
    /// sessions of the window generate or are driven from Telegram. On a
    /// failure the selected session shows it as an error row.
    ///
    /// - Returns: The new session; `nil` when it could not open, or when the
    ///   window closed meanwhile (the session is closed then).
    @discardableResult
    public func openNewSession() async -> ZenWindowSession? {
        guard !isClosed else { return nil }
        let source = selectedSession
        beginOpening()
        defer { endOpening() }
        do {
            let session = try await runtime.openWindow(workspace: workspace, inheritingSelectionFrom: source?.id)
            guard !isClosed else {
                await session.close()
                return nil
            }
            add(session, selecting: true)
            return session
        } catch {
            guard !isClosed else { return nil }
            let shown = selectedSession.flatMap { $0.isClosed ? nil : $0 } ?? sessions.last { !$0.isClosed }
            shown?.appendLocalNow(.local(text: Self.newSessionFailureText(for: error), isFailure: true))
            return nil
        }
    }

    // MARK: - Selection

    /// Shows `session`; nothing for a session that is not of this window.
    public func select(_ session: ZenWindowSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        setSelection(session)
    }

    /// Shows the saved session `name`: selects the session of the window
    /// that shows it already (``ZenWindowSession/currentSavedSessionName``),
    /// else loads it into the selected session
    /// (``ZenWindowSession/loadSavedSession(named:)``).
    public func showSavedSession(named name: String) {
        if let session = sessions.first(where: { !$0.isClosed && $0.currentSavedSessionName == name }) {
            select(session)
            return
        }
        selectedSession?.loadSavedSession(named: name)
    }

    // MARK: - Closing

    /// Closes `session` (``ZenWindowSession/close()``) and removes it from
    /// the window. When it was the selected one, the session after it is
    /// selected, else the one before it. Once no session is left the window
    /// asks to close (``closeRequested``). Nothing for a session that is not
    /// of this window.
    public func closeSession(_ session: ZenWindowSession) async {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        session.closeRequestHandler = nil
        sessions.remove(at: index)
        if selectedSession === session {
            let next = index < sessions.count ? sessions[index] : sessions.last
            setSelection(next)
        }
        await session.close()
        if sessions.isEmpty, !isClosed, !closeRequested {
            closeRequested = true
        }
    }

    /// The system window closes: closes every session of the window, also
    /// one still opening, and returns once they all closed. It does not set
    /// ``closeRequested``. A second call does nothing.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let closing = sessions
        if !sessions.isEmpty {
            sessions = []
        }
        setSelection(nil)
        for session in closing {
            session.closeRequestHandler = nil
        }
        await withTaskGroup(of: Void.self) { group in
            for session in closing {
                group.addTask { await session.close() }
            }
        }
        // A session still opening closes as soon as it opens.
        if openingCount > 0 {
            await withCheckedContinuation { continuation in
                openingsDidEnd.append(continuation)
            }
        }
    }

    // MARK: - Private

    private func add(_ session: ZenWindowSession, selecting: Bool) {
        session.closeRequestHandler = { [weak self] session in
            Task { @MainActor [weak self] in
                await self?.closeSession(session)
            }
        }
        sessions.append(session)
        sessionDidJoin?(session)
        if selecting {
            setSelection(session)
        }
    }

    private func setSelection(_ session: ZenWindowSession?) {
        guard selectedSession !== session else { return }
        selectedSession = session
        selectionDidChange?(session)
    }

    private func beginOpening() {
        openingCount += 1
        if !isOpeningSession {
            isOpeningSession = true
        }
    }

    private func endOpening() {
        openingCount -= 1
        guard openingCount == 0 else { return }
        if isOpeningSession {
            isOpeningSession = false
        }
        let waiting = openingsDidEnd
        openingsDidEnd = []
        for continuation in waiting {
            continuation.resume()
        }
    }

    // MARK: - Texts

    /// The text of a failure to open the first session of a window.
    nonisolated static func describe(_ error: any Error) -> String {
        if let hostError = error as? ChatSessionHostError {
            switch hostError {
            case .shutDown:
                return "ZenCODE is shutting down."
            default:
                return "Could not open a session: \(hostError)."
            }
        }
        if let localized = (error as? any LocalizedError)?.errorDescription {
            return localized
        }
        return error.localizedDescription
    }

    /// The row a failure to open a new session of the window shows.
    nonisolated static func newSessionFailureText(for error: any Error) -> String {
        if let hostError = error as? ChatSessionHostError {
            if case .shutDown = hostError {
                return ZenWindowSession.text(for: hostError)
            }
            return "ZenCODE: could not open a new session: \(hostError)."
        }
        let detail = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        return "ZenCODE: could not open a new session: \(detail)"
    }
}
