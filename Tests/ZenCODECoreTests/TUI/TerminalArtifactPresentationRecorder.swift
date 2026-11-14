//
//  TerminalArtifactPresentationRecorder.swift
//  ZenCODE
//
//  The file artifacts the session controller presents, recorded for the
//  terminal suites: the terminal writes none of them in its transcript any
//  more (they are seen in the `/artifacts` panel), so the suites read what was
//  presented here instead of in the chat output.
//

import Foundation
@testable import ZenCODECore

/// Records every live and sealed file artifact the controller presents. As an
/// observer of the terminal's session it receives them in the same order, and
/// just before, the terminal's presenter does.
@ChatSessionActor
final class TerminalArtifactPresentationRecorder: ChatSessionObserver {
    /// One presentation of the controller.
    enum Presentation: Equatable {
        case live([SessionFileArtifactHistory.Turn], agentID: String?)
        case sealed(SessionFileArtifactHistory.Turn)
    }

    private(set) var presentations: [Presentation] = []

    /// Attaches a recorder to the session of `terminal`.
    static func attached(to terminal: TerminalChat) -> TerminalArtifactPresentationRecorder {
        let recorder = TerminalArtifactPresentationRecorder()
        terminal.chatSession.addObserver(recorder)
        return recorder
    }

    /// The turns presented, in order.
    var turns: [SessionFileArtifactHistory.Turn] {
        presentations.flatMap { presentation -> [SessionFileArtifactHistory.Turn] in
            switch presentation {
            case let .live(turns, _): turns
            case let .sealed(turn): [turn]
            }
        }
    }

    /// The agent of each live presentation, `nil` for the root agent.
    var liveAgentIDs: [String?] {
        presentations.compactMap { presentation in
            if case let .live(_, agentID) = presentation { return .some(agentID) }
            return nil
        }
    }

    /// The sealed presentations.
    var sealedTurns: [SessionFileArtifactHistory.Turn] {
        presentations.compactMap { presentation in
            if case let .sealed(turn) = presentation { return turn }
            return nil
        }
    }

    /// The Markdown of the turns presented, as the terminal wrote a live
    /// artifact in the chat before the `/artifacts` panel.
    var markdown: String {
        TerminalChat.renderFileArtifacts(turns, includeHistoryHeadings: false)
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        presentations.append(.live(turns, agentID: agentID))
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        presentations.append(.sealed(turn))
    }
}
