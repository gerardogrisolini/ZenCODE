//
//  ChatShellSnapshot.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation

/// What a shell (a host app's sidebar, its window list) shows about every
/// session of one ``ChatSessionHost``: the summary of the session each slot
/// runs, the saved sessions of the workspaces the slots run sessions in, and
/// the Telegram state of the process. The host publishes it
/// (``ChatSessionHost/shellSnapshot``, ``ChatSessionHost/shellSnapshots()``);
/// it only aggregates what the sessions already summarize and creates no
/// reducer of its own.
///
/// A snapshot is transient, like a session's: it is never saved.
public struct ChatShellSnapshot: Sendable, Equatable {
    /// The summary of the session each open slot runs now, by slot; a slot
    /// between sessions has none. A slot whose session has a reducer (it
    /// publishes state, or Telegram drives it) shows the reducer's
    /// ``ChatSessionSnapshot/summary``; any other slot a summary built from
    /// the incarnation with the reducer's rules: its workspace, the saved
    /// session's name or a name derived from the first prompt, generating
    /// while a prompt is reserved, the origin of the turn generating, and no
    /// pending requests, which only a reducer publishes.
    public internal(set) var sessions: [ChatSlotID: ChatSessionSummary] = [:]
    /// The saved sessions of each workspace an open slot runs sessions in, by
    /// working directory (``ChatSessionSummary/workspace``), most recently
    /// saved first. Empty until a shell observes the host
    /// (``ChatSessionHost/shellSnapshots()``) or asks
    /// (``ChatSessionHost/refreshShellSnapshot()``); then read again, off the
    /// chat actor, when a slot starts another session and when a session of
    /// the host is saved or deleted, never on a timer.
    public internal(set) var savedSessions: [URL: [ChatSavedSessionSummary]] = [:]
    /// The Telegram link of the process.
    public internal(set) var telegram = ChatShellTelegramState()

    init() {}
}

/// The Telegram link of one process, as a shell shows it.
public struct ChatShellTelegramState: Sendable, Equatable {
    /// Whether setup configured Telegram: enabled, with a bot token, a paired
    /// chat and owner, and its routes (``AgentTelegramSettingsManifest/isEnabled``,
    /// what the terminal offers `/telegram` on). Read from the settings when
    /// a shell first observes the host and on
    /// ``ChatSessionHost/refreshShellSnapshot()``; `false` before.
    public internal(set) var isConfigured = false
    /// Whether the host's Bot API poller runs a long poll now. Read when a
    /// slot hands itself to Telegram or takes itself back, when a slot
    /// closes, and on ``ChatSessionHost/refreshShellSnapshot()``, while a
    /// shell observes the host; `false` before the first `/telegram on`.
    public internal(set) var isPolling = false
    /// The slots the linked chat drives now (``ChatSlotChannel/telegram``).
    public internal(set) var drivenSlots: Set<ChatSlotID> = []

    init() {}
}
