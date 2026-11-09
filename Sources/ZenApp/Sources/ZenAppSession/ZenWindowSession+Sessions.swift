//
//  ZenWindowSession+Sessions.swift
//  ZenApp
//
//  The session operations of a window (new, save, load, delete) and the
//  loading indicator of a sidebar load.
//

import Foundation
import ToolCore
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Sessions

    /// `/sessions new`. Refused while a line runs. Selects the conversation
    /// first, as every session operation does, so its result shows.
    public func startNewSession() {
        runOperationLine("/sessions new")
    }

    /// `/sessions save`. Refused while a line runs.
    public func saveSession() {
        runOperationLine("/sessions save")
    }

    /// Loads the saved session `name` of the workspace into a new
    /// incarnation, with the loading indicator (``loadingSavedSessionName``,
    /// ``loadingSavedSessionStep``) until the window shows how the load
    /// ended. Refused while a line runs, and while Telegram drives the slot
    /// (the load does not pass through the host's admission of a line).
    public func loadSavedSession(named name: String) {
        guard !isClosed else { return }
        selectTab(.chat)
        guard !refusedWhileDormant() else { return }
        guard !isBusy else {
            refuseWhileBusy(command: "/sessions")
            return
        }
        let generation = beginSavedSessionLoad(named: name)
        startExclusive { [weak self] _ in
            await self?.performLoad(named: name)
            await self?.endSavedSessionLoad(generation)
        }
    }

    /// Deletes the saved session `name` of the workspace. Refused while a
    /// line runs, and while Telegram drives the slot (the delete does not
    /// pass through the host's admission of a line).
    public func deleteSavedSession(named name: String) {
        guard !isClosed else { return }
        selectTab(.chat)
        guard !refusedWhileDormant() else { return }
        guard !isBusy else {
            refuseWhileBusy(command: "/sessions")
            return
        }
        startExclusive { [weak self] _ in
            await self?.performDelete(named: name)
        }
    }

    private func runOperationLine(_ line: String) {
        guard !isClosed else { return }
        selectTab(.chat)
        guard !isBusy else {
            refuseWhileBusy(command: ZenLineRoute.commandToken(of: line))
            return
        }
        startLine(line)
    }

    func refuseWhileBusy(command: String) {
        appendLocalNow(.local(
            text: ZenLineRoute.generatingCommandMessage(
                for: command,
                registry: ZenAppCommands.registry,
                context: commandContext
            ),
            isFailure: true
        ))
    }

    private func performLoad(named name: String) async {
        do {
            let outcome = try await sessionHost.loadSavedSession(in: slotID, name: name, checkpointEntryID: nil)
            await ZenWindowSteps.present(outcome.notices, in: sessionHost, slotID: slotID)
        } catch let error as ChatSessionHostError {
            await appendLocal(.local(text: Self.text(for: error), isFailure: true))
        } catch {
            await appendLocal(.local(text: error.localizedDescription, isFailure: true))
        }
        guard !isClosed else { return }
        // A load changes the incarnation, or tried to.
        await refreshStatus()
        refreshGitStatus()
    }

    private func performDelete(named name: String) async {
        guard let controller = await sessionHost.incarnation(in: slotID)?.controller else {
            await appendLocal(.local(text: Self.text(for: ChatSessionHostError.noSession), isFailure: true))
            return
        }
        do {
            let outcome = try await controller.deleteSavedSessions(names: [name])
            await ZenWindowSteps.present(outcome.notices, in: sessionHost, slotID: slotID)
        } catch {
            await appendLocal(.local(text: error.localizedDescription, isFailure: true))
        }
    }

    // MARK: - Loading indicator

    /// Shows the loading indicator of the sidebar load of `name`, in place of
    /// the one of an earlier load; returns the load's generation.
    private func beginSavedSessionLoad(named name: String) -> Int {
        savedSessionLoadGeneration &+= 1
        savedSessionLoadAnchor = nil
        loadingSavedSessionName = name
        loadingSavedSessionStep = .reading
        return savedSessionLoadGeneration
    }

    /// The sidebar load that shows reached `step` (a hook of the slot): the
    /// indicator moves to it, never back. A load the sidebar did not start
    /// (a typed `/sessions` line) shows no step.
    func savedSessionLoadDidReach(_ step: ZenSavedSessionLoadStep) {
        guard !isClosed, loadingSavedSessionName != nil,
              let current = loadingSavedSessionStep, step > current
        else { return }
        loadingSavedSessionStep = step
    }

    /// The sidebar load of `generation` ended, loaded or not. The restored
    /// log reaches the window on the snapshot stream, maybe after the load
    /// returned: the indicator stays until the window applied the slot's
    /// reducer as it is now (the restored rows, or the failure anchored on
    /// it), so the welcome view never shows in between. It clears at once
    /// when the slot has no session or the window already applied it;
    /// nothing waits here, so the line ends at once.
    private func endSavedSessionLoad(_ generation: Int) async {
        guard generation == savedSessionLoadGeneration, loadingSavedSessionName != nil else { return }
        let anchor = await ZenWindowSteps.anchor(in: sessionHost, slotID: slotID)
        guard generation == savedSessionLoadGeneration, loadingSavedSessionName != nil else { return }
        guard !isClosed, let anchor else {
            clearSavedSessionLoad()
            return
        }
        savedSessionLoadAnchor = anchor
        settleSavedSessionLoad()
    }

    /// Clears the indicator of a sidebar load that ended once the applied
    /// snapshot of ``current`` reached its anchor. Until the window follows
    /// the anchor's incarnation it waits: ``follow(_:)`` clears it when the
    /// window follows another one.
    func settleSavedSessionLoad() {
        guard let anchor = savedSessionLoadAnchor,
              anchor.epoch == current.epoch,
              let snapshot,
              snapshot.epoch == anchor.epoch,
              ZenLocalTranscriptItem.anchorSequence(in: snapshot) >= anchor.sequence
        else { return }
        clearSavedSessionLoad()
    }

    func clearSavedSessionLoad() {
        savedSessionLoadAnchor = nil
        if loadingSavedSessionName != nil {
            loadingSavedSessionName = nil
        }
        if loadingSavedSessionStep != nil {
            loadingSavedSessionStep = nil
        }
    }
}
