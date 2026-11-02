//
//  ChatSessionHost+Shell.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation
import ToolCore

/// The shell snapshot of a host (``ChatShellSnapshot``): what a shell shows
/// about every session of the process, aggregated from what the sessions
/// already summarize.
///
/// The sessions and the slots Telegram drives are in memory and kept current
/// without suspending: the slot reports every change of its incarnation, of
/// the channel that drives it, and of the state its controller presents, and
/// a reducer the host created reports every change of its summary; a new or
/// loaded session is shown once, with the session, never as a slot without
/// one in between. The saved sessions, the Telegram settings, and the
/// poller's state are read only while a shell observes the host, from its
/// first ``shellSnapshots()`` or ``refreshShellSnapshot()`` until its last
/// stream ends, never on a timer: the saved sessions of a workspace when a
/// slot of it starts another session and when a session of the host is
/// saved or deleted, the settings and the poller together when a slot hands
/// itself to Telegram, takes itself back, or closes, and everything on
/// request. Disk reads run off the chat actor and are applied on it, dropped
/// when a later read of the same thing overtook them or the workspace is no
/// longer open. The workspaces are keyed by their standardized URL
/// (`standardizedFileURL`).
extension ChatSessionHost {
    // MARK: - Observation

    /// A stream of the shell snapshots: the current one at once, then one
    /// after every change. Like a reducer's snapshots, a slow consumer skips
    /// to the newest. Each call returns a new stream; it ends when the
    /// consumer stops iterating, on ``shutdown(keepingExternalTools:)``,
    /// after the last snapshot, or when the host is released, and at once
    /// after a shutdown. The first call starts observing the host: the saved
    /// sessions and the Telegram state are read, off the chat actor, and
    /// follow in later snapshots; the observation stops when the last open
    /// stream ends.
    public func shellSnapshots() -> AsyncStream<ChatShellSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ChatShellSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(shellSnapshot)
        guard !isShutDown else {
            continuation.finish()
            return stream
        }
        let token = UUID()
        shellStreams[token] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @ChatSessionActor in
                self.shellStreamDidEnd(token)
            }
        }
        startShellObservationIfNeeded()
        return stream
    }

    /// Reads again what the shell snapshot does not keep in memory, off the
    /// chat actor, and publishes it: the saved sessions of every workspace an
    /// open slot runs sessions in, whether Telegram is configured, and
    /// whether the poller runs. The host is observed from then on, until the
    /// last open stream of ``shellSnapshots()`` ends (see
    /// ``ChatShellSnapshot/savedSessions``). Nothing happens after a
    /// shutdown.
    public func refreshShellSnapshot() async {
        guard !isShutDown else { return }
        isShellObserved = true
        for workspace in shellWorkspaces.sorted(by: { $0.path < $1.path }) {
            await readShellSavedSessions(in: workspace)
        }
        await readShellTelegramState()
    }

    /// The stream `token` ended: the shell stops observing the host with the
    /// last one, so nothing is read on disk for nobody.
    private func shellStreamDidEnd(_ token: UUID) {
        guard shellStreams.removeValue(forKey: token) != nil, shellStreams.isEmpty else { return }
        isShellObserved = false
    }

    // MARK: - Sessions

    /// The summary of the session `slot` runs, the one place the shell reads
    /// it: the reducer's when the incarnation has one, otherwise built from
    /// the incarnation with the reducer's rules (see
    /// ``ChatShellSnapshot/sessions``); `nil` between sessions.
    func shellSummary(of slot: ChatSlot) -> ChatSessionSummary? {
        guard let incarnation = slot.incarnation else { return nil }
        if let reducer = incarnation.reducer {
            return reducer.snapshot.summary
        }
        let controller = incarnation.controller
        var summary = ChatSessionSummary(workspace: slot.workingDirectory, activeChannel: slot.defaultOrigin)
        summary.title = controller.savedSessionState.savedSessionName?.nilIfBlank
            ?? ChatSessionController.derivedSessionName(
                fromFirstPromptIn: controller.transcript.isEmpty ? controller.history : controller.transcript
            )
        summary.isGenerating = incarnation.activePromptID != nil
        if let promptID = incarnation.activePromptID, promptID == slot.telegramTurnPromptID {
            // The turn generating is the Telegram channel's.
            summary.activeChannel = .telegram
        }
        return summary
    }

    /// The observer of what the shell shows of `slot`: the slot's
    /// ``ChatSlot/shellFactsDidChange``, and the `summaryDidChange` of every
    /// reducer the host creates for it.
    func shellSummaryObserver(for slot: ChatSlot) -> @ChatSessionActor () -> Void {
        { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.shellSlotDidChange(slot)
        }
    }

    /// `slot` opened: the shell follows it, and reads the saved sessions of
    /// its workspace when no other slot runs sessions in it.
    func shellSlotDidOpen(_ slot: ChatSlot) {
        slot.shellFactsDidChange = shellSummaryObserver(for: slot)
        let workspace = Self.shellWorkspace(of: slot)
        let isNewWorkspace = !slots.values.contains {
            $0 !== slot && Self.shellWorkspace(of: $0) == workspace
        }
        shellSlotDidChange(slot)
        if isNewWorkspace {
            scheduleShellSavedSessionsRead(in: workspace)
        }
    }

    /// Runs `body`, which replaces the incarnation of `slot`, with what the
    /// shell shows of the slot held, then shows the slot once: the session
    /// that ends, its refused requests, and the slot left without session
    /// in between are never published.
    func holdingShellFacts<Value>(of slot: ChatSlot, _ body: () -> Value) -> Value {
        slot.holdsShellFacts = true
        defer {
            slot.holdsShellFacts = false
            shellSlotDidChange(slot)
        }
        return body()
    }

    /// What the shell shows of `slot` changed: its summary and whether
    /// Telegram drives it are read again, and a new incarnation reads the
    /// saved sessions of its workspace. Nothing happens while the host
    /// replaces the slot's incarnation (``holdingShellFacts(of:_:)``).
    func shellSlotDidChange(_ slot: ChatSlot) {
        guard !isShutDown, !slot.holdsShellFacts, slots[slot.id] === slot else { return }
        var next = shellSnapshot
        next.sessions[slot.id] = shellSummary(of: slot)
        next.telegram.drivenSlots = shellDrivenSlots
        publishShellSnapshot(next)
        if let epoch = slot.incarnation?.epoch, slot.shellSavedSessionsEpoch != epoch {
            let isFirstIncarnation = slot.shellSavedSessionsEpoch == nil
            slot.shellSavedSessionsEpoch = epoch
            // The slot's opening reads them already.
            if !isFirstIncarnation {
                scheduleShellSavedSessionsRead(in: Self.shellWorkspace(of: slot))
            }
        }
    }

    /// `slot` closed: its session leaves the shell, and so do the saved
    /// sessions of its workspace when no other slot runs sessions in it.
    func shellSlotDidClose(_ slot: ChatSlot) {
        guard !isShutDown else { return }
        var next = shellSnapshot
        next.sessions.removeValue(forKey: slot.id)
        next.telegram.drivenSlots = shellDrivenSlots
        let workspace = Self.shellWorkspace(of: slot)
        if !shellWorkspaces.contains(workspace) {
            next.savedSessions.removeValue(forKey: workspace)
            shellSavedSessionsReads.removeValue(forKey: workspace)
        }
        publishShellSnapshot(next)
    }

    /// A session of the host was saved or deleted in `workspace`: its saved
    /// sessions are read again.
    func savedSessionsDidChange(in workspace: URL) {
        scheduleShellSavedSessionsRead(in: workspace.standardizedFileURL)
    }

    /// The host shut down: the last snapshot has no session, and every
    /// stream ends after it.
    func endShellObservation() {
        var next = shellSnapshot
        next.sessions = [:]
        next.savedSessions = [:]
        next.telegram.drivenSlots = []
        next.telegram.isPolling = false
        if next != shellSnapshot {
            shellSnapshot = next
            for continuation in shellStreams.values {
                continuation.yield(next)
            }
        }
        let streams = shellStreams
        shellStreams.removeAll()
        isShellObserved = false
        for continuation in streams.values {
            continuation.finish()
        }
    }

    // MARK: - Reads

    /// An observation that starts reads what nobody read before it.
    private func startShellObservationIfNeeded() {
        guard !isShellObserved else { return }
        isShellObserved = true
        for workspace in shellWorkspaces {
            scheduleShellSavedSessionsRead(in: workspace)
        }
        scheduleShellTelegramRead()
    }

    private func scheduleShellSavedSessionsRead(in workspace: URL) {
        guard isShellObserved, !isShutDown else { return }
        Task { [weak self] in
            await self?.readShellSavedSessions(in: workspace)
        }
    }

    /// Reads the Telegram settings and the poller's state again, while a
    /// shell observes the host.
    func scheduleShellTelegramRead() {
        guard isShellObserved, !isShutDown else { return }
        Task { [weak self] in
            await self?.readShellTelegramState()
        }
    }

    private func readShellSavedSessions(in workspace: URL) async {
        let read = nextShellRead()
        shellSavedSessionsReads[workspace] = read
        let summaries = if let reader = shellSavedSessionsReader {
            await reader(workspace)
        } else {
            await Self.savedSessionSummaries(in: workspace)
        }
        guard let summaries,
              !isShutDown,
              shellWorkspaces.contains(workspace),
              shellSavedSessionsReads[workspace] == read else {
            return
        }
        var next = shellSnapshot
        next.savedSessions[workspace] = summaries
        publishShellSnapshot(next)
    }

    /// Reads whether the settings configure Telegram and whether the poller
    /// runs, and publishes both in one snapshot, so that they never come
    /// from reads made at different times.
    private func readShellTelegramState() async {
        let read = nextShellRead()
        shellTelegramRead = read
        let isConfigured = await Self.telegramIsConfigured()
        // The poller exists from the first `/telegram on`; it is never
        // created to be read.
        let isPolling = await telegramDispatcherStorage?.isPolling() ?? false
        guard !isShutDown, shellTelegramRead == read else { return }
        var next = shellSnapshot
        next.telegram.isConfigured = isConfigured
        next.telegram.isPolling = isPolling
        publishShellSnapshot(next)
    }

    private func nextShellRead() -> UInt64 {
        let read = nextShellReadValue
        nextShellReadValue &+= 1
        return read
    }

    /// The saved sessions of `workspace`, most recently saved first, read off
    /// the chat actor; `nil` when the store cannot be read. The store is
    /// only listed: migrating its files would move a save in progress.
    @concurrent
    private nonisolated static func savedSessionSummaries(in workspace: URL) async -> [ChatSavedSessionSummary]? {
        guard let sessions = try? TerminalSessionStore.savedSessions(for: workspace, migrating: false) else {
            return nil
        }
        return sessions.map(ChatSavedSessionSummary.init)
    }

    /// Whether the settings configure Telegram, read off the chat actor:
    /// the rule the terminal offers `/telegram` by.
    @concurrent
    private nonisolated static func telegramIsConfigured() async -> Bool {
        AgentSettingsManifestStore.load()?.telegram?.isEnabled == true
    }

    // MARK: - State

    /// The working directories of the open slots, standardized.
    private var shellWorkspaces: Set<URL> {
        Set(slots.values.map(Self.shellWorkspace(of:)))
    }

    /// The key of the workspace of `slot` in the shell: its standardized
    /// working directory, so that two spellings of one folder are one
    /// workspace.
    private static func shellWorkspace(of slot: ChatSlot) -> URL {
        slot.workingDirectory.standardizedFileURL
    }

    /// The slots the linked chat drives now.
    private var shellDrivenSlots: Set<ChatSlotID> {
        Set(slots.values.filter { $0.activeChannel == .telegram }.map(\.id))
    }

    /// Publishes `next` when it differs from the current snapshot.
    private func publishShellSnapshot(_ next: ChatShellSnapshot) {
        guard next != shellSnapshot else { return }
        shellSnapshot = next
        for continuation in shellStreams.values {
            continuation.yield(next)
        }
    }
}
