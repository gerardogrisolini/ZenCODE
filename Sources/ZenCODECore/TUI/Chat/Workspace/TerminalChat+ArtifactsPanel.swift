//
//  TerminalChat+ArtifactsPanel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 08/11/26.
//

import Foundation

extension TerminalChat {
    /// The input panel's mode while the `/artifacts` panel shows a file's
    /// diff. As the `/subagent` detail, it is no overlay of the prompt: below
    /// the diff the operator keeps typing, completing and sending the draft.
    nonisolated static let artifactsDetailPanelOverride = TerminalPanelModeOverride(
        modeText: "Artifacts",
        helpText: subAgentDetailPanelOverride.helpText
    )

    /// The input panel's mode while the `/artifacts` panel lists the changed
    /// files, which own every key of the panel until one is opened.
    nonisolated static let artifactsListPanelOverride = TerminalPanelModeOverride(
        modeText: "Artifacts",
        helpText: subAgentListPanelOverride.helpText
    )

    /// The input panel's mode that goes with each routing of the panel keys
    /// to the `/artifacts` panel: ``artifactsListPanelOverride`` for the file
    /// list, ``artifactsDetailPanelOverride`` for a file's diff, none once
    /// the panel is closed.
    nonisolated static func artifactsPanelModeOverride(
        for mode: TerminalInteractiveLineReader.SubAgentDetailMode
    ) -> TerminalPanelModeOverride? {
        switch mode {
        case .closed: nil
        case .list: artifactsListPanelOverride
        case .detail: artifactsDetailPanelOverride
        }
    }

    // MARK: - /artifacts

    /// `/artifacts`: opens the panel of the files the session changed
    /// (``TerminalArtifactsPanelController``), the turn in progress
    /// included, with the layout and the keys of `/subagent`: the list of the
    /// files, or directly the diff of the only one. It replaces a panel
    /// already open (the `/subagent` detail, or another `/artifacts` panel)
    /// and runs while a prompt is generating.
    ///
    /// It accepts no arguments and, without artifacts, writes the notices of
    /// the shared `/artifacts`
    /// (``ChatSessionNotice/artifactsTakeNoArguments`` and
    /// ``ChatSessionNotice/noFileArtifacts``). Without the interactive layout
    /// (``detailPanelScreen()``) it prints the artifact history as the shared
    /// command does, the only way to see the artifacts there.
    func handleArtifactsCommand(_ command: String) async {
        guard Self.slashCommandArguments(from: command, commandPrefix: "/artifacts").isEmpty else {
            await writeSessionNotice(.artifactsTakeNoArguments)
            return
        }
        guard let screen = detailPanelScreen() else {
            _ = await terminalAction(presenting: await chatSession.runArtifactsCommand(line: command))
            return
        }
        let revision = fileArtifactsRevision
        let snapshot = await chatSession.fileArtifactSnapshot()
        guard !TerminalArtifactsPanelController.entries(snapshot).isEmpty else {
            await writeSessionNotice(.noFileArtifacts)
            return
        }
        await closeDetailPanel(reason: .replaced)
        await openDetailPanel(.artifacts(snapshot, revision: revision), on: screen)
    }

    /// The `/artifacts` part of ``openDetailPanel(_:on:)``: creates the
    /// controller of the panel drawn in `session`, makes it the open panel,
    /// routes the panel keys to it and opens it on `snapshot`, on the diff of
    /// the only file or on the list. A change reported since `revision`, the
    /// revision `snapshot` was read at, is read again at once.
    func openArtifactsPanel(
        _ snapshot: ChatFileArtifactSnapshot,
        revision: UInt64,
        in session: TerminalModalSession
    ) async {
        let chatSession = chatSession
        let controller = TerminalArtifactsPanelController(environment: .init(
            snapshot: {
                await chatSession.fileArtifactSnapshot()
            },
            viewport: { session.dialogViewport() },
            present: { lines in
                session.updateDialog(TerminalDialogPresentation(prompt: lines.joined(separator: "\n")))
            },
            isCancelled: { session.isCancelled },
            onClosed: { [weak self] reason in
                await self?.closeDetailPanel(reason: reason)
            },
            modeDidChange: { [weak self] isChoosing in
                await self?.detailPanelModeDidChange(isChoosing: isChoosing, session: session)
            },
            standardErrorIsTerminal: AgentOutput.standardErrorIsTerminal
        ))
        detailPanel = TerminalDetailPanel(content: .artifacts(controller), session: session)

        let entries = TerminalArtifactsPanelController.entries(snapshot)
        if entries.count == 1 {
            await setDetailPanelMode(.detail, kind: .artifacts)
            controller.open(entryID: entries[0].id, in: snapshot)
        } else {
            await setDetailPanelMode(.list, kind: .artifacts)
            controller.open(choosing: snapshot)
        }
        if fileArtifactsRevision != revision {
            controller.reload()
        }
    }

    /// The session's file artifacts may have changed: a live or sealed
    /// artifact was recorded, or a turn finished after its file-change summary
    /// was collected. The terminal writes none of them in the transcript; an
    /// open `/artifacts` panel reads them again
    /// (``TerminalArtifactsPanelController/reload()``).
    func fileArtifactsDidChange() {
        fileArtifactsRevision &+= 1
        guard case let .artifacts(controller)? = detailPanel?.content else { return }
        controller.reload()
    }
}
