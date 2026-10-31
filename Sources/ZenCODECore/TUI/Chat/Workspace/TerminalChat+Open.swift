//
//  TerminalChat+Open.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini.
//

import Foundation

/// A file path or URL referenced somewhere in the conversation that the
/// `/open` command can hand off to the system `open` utility. Compatibility
/// name of the shared ``ChatOpenCandidate``.
typealias TerminalOpenCandidate = ChatOpenCandidate

extension TerminalChat {
    /// `/open`, run by the shared controller (see
    /// ``ChatSessionController/runOpenCommand(line:)``).
    public func handleOpenCommand(_ command: String) async {
        await writeSessionNotices(await chatSession.runOpenCommand(line: command).notices)
    }

    /// See ``ChatSessionController/attachmentCandidate(from:)``.
    nonisolated static func attachmentCandidate(
        from attachment: AgentRuntimeAttachment
    ) -> TerminalOpenCandidate? {
        ChatSessionController.attachmentCandidate(from: attachment)
    }

    /// See ``ChatSessionController/extractOpenCandidates(from:workingDirectory:userHomeDirectoryURL:)``;
    /// `~` stands for the user's home, as in the terminal chat's environment.
    nonisolated static func extractOpenCandidates(
        from text: String,
        workingDirectory: URL
    ) -> [TerminalOpenCandidate] {
        ChatSessionController.extractOpenCandidates(
            from: text,
            workingDirectory: workingDirectory,
            userHomeDirectoryURL: UserHomeDirectory.current()
        )
    }

    /// See ``ChatSessionNoticeText/openCandidateListText(_:)``.
    nonisolated static func renderOpenCandidateList(_ candidates: [TerminalOpenCandidate]) -> String {
        ChatSessionNoticeText.openCandidateListText(candidates)
    }
}
