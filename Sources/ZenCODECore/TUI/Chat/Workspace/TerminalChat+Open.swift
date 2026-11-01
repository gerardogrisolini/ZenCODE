//
//  TerminalChat+Open.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini.
//

import Foundation

extension TerminalChat {
    /// `/open`, run by the shared controller (see
    /// ``ChatSessionController/runOpenCommand(line:)``).
    public func handleOpenCommand(_ command: String) async {
        await writeSessionNotices(await chatSession.runOpenCommand(line: command).notices)
    }

    /// See ``ChatSessionController/attachmentCandidate(from:)``.
    nonisolated static func attachmentCandidate(
        from attachment: AgentRuntimeAttachment
    ) -> ChatOpenCandidate? {
        ChatSessionController.attachmentCandidate(from: attachment)
    }

    /// See ``ChatSessionController/extractOpenCandidates(from:workingDirectory:userHomeDirectoryURL:)``;
    /// `~` stands for the user's home, as in the terminal chat's environment.
    nonisolated static func extractOpenCandidates(
        from text: String,
        workingDirectory: URL
    ) -> [ChatOpenCandidate] {
        ChatSessionController.extractOpenCandidates(
            from: text,
            workingDirectory: workingDirectory,
            userHomeDirectoryURL: UserHomeDirectory.current()
        )
    }

    /// See ``ChatSessionNoticeText/openCandidateListText(_:)``.
    nonisolated static func renderOpenCandidateList(_ candidates: [ChatOpenCandidate]) -> String {
        ChatSessionNoticeText.openCandidateListText(candidates)
    }
}
