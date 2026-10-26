//
//  DS4HintsNote.swift
//  ZenCODE
//
//  The `/ds4 hints on|off` state machine, a port of ds4-agent's `agent_hints`
//  (ds4_agent.c:124-134, 1480-1534). Hints are a runtime preference only: they
//  start off, are never part of settings or saved sessions, and take effect
//  at the next conversation boundary, when the note returned by
//  `DS4HintsState.nextNote()` is recorded on the next user message
//  (`DS4MessageKeys.hintsNote`) and rendered as a system message before it.
//
//  Semantics (identical to ds4-agent):
//  - the full instructions are sent once per live context, not on each enable;
//  - after that, switching on sends "Produce them from now on.", switching off
//    sends the "disabled" note (so on -> off DOES add a note);
//  - several changes before a boundary coalesce to the latest request, and a
//    never-enabled session never gets a note;
//  - a compacted or replaced transcript forgets the instructions and may still
//    contain an old on/off note, so the next boundary states the setting again.
//

import Foundation

/// Texts of the hints notes (ds4_agent.c:1480-1490, 1508-1510), verbatim.
enum DS4HintsNotes {
    /// Sent the first time hints are on in a live context.
    static let instructions =
        "The user enabled programming hints. Occasionally explain a useful concept "
        + "behind the current work: a design choice, failure mechanism, trade-off, "
        + "or way to verify correctness. Base each hint on code or results you have "
        + "actually examined. Write one or two sentences as a normal Markdown "
        + "blockquote starting with > **Hint:**. Hints are prose, not tool calls. "
        + "Put them after the relevant discovery, including between tool calls. "
        + "Prefer no hint to routine narration, repetition, or generic advice. "
        + "Do not invent personal experience or a learner profile. Keep working "
        + "without waiting for an answer. Later system notes may enable or disable "
        + "hints; follow the latest setting.\n"
    /// Sent when hints are switched on again after the instructions.
    static let enabled = "The user enabled programming hints. Produce them from now on.\n"
    /// Sent when hints are switched off after having been applied.
    static let disabled = "Programming hints are disabled. Do not produce teaching asides; "
        + "continue the task normally.\n"
}

/// Per-session hints preference and what the model's context already says.
struct DS4HintsState: Sendable, Equatable {
    /// What the notes already in the context last stated.
    enum Applied: Sendable, Equatable {
        /// No note was ever recorded.
        case unset
        case off
        case on
        /// The context may hold an old on/off note (after compaction or a restore).
        case unknown
    }

    /// The user's current setting.
    var enabled = false
    /// The full instructions are already in the context.
    var instructed = false
    var applied: Applied = .unset

    /// `agent_hints_note`: the note to record at this boundary, if any. Mutates
    /// the state only when it returns a note, so asking twice is safe.
    mutating func nextNote() -> String? {
        let note: String
        if enabled, !instructed {
            note = DS4HintsNotes.instructions
            instructed = true
        } else if applied != .unset, applied != (enabled ? .on : .off) {
            note = enabled ? DS4HintsNotes.enabled : DS4HintsNotes.disabled
        } else {
            return nil
        }
        applied = enabled ? .on : .off
        return note
    }

    /// `agent_hints_compacted`: the context was compacted or replaced; the
    /// retained tail may still contain an old on/off note.
    mutating func contextCompacted() {
        if applied != .unset {
            applied = .unknown
        }
        instructed = false
    }

    /// A restored transcript carries hints notes of an earlier run: whatever
    /// the setting is now must be stated again at the next boundary.
    mutating func contextRestoredWithNotes() {
        applied = .unknown
        instructed = false
    }
}
