//
//  SharedChatMentionCatalog.swift
//  ZenCODE
//

import Foundation

/// Actor-isolated catalogue that maps stable participant identifiers to
/// human-readable `@mention` handles and back.
///
/// Design constraints encoded here:
/// * handles are derived from the participant's display name, so the
///   autocomplete list is readable (`@dev`, `@code-reviewer`) instead of an
///   opaque `@agent-Base64` blob;
/// * internal routing is always by stable participant id: a handle is only a
///   presentation alias, never an identity, so a mutable or duplicated name can
///   never reach the wrong agent;
/// * aliases are never recycled within a session: once `dev` is assigned it is
///   reserved for the rest of the session even if that participant leaves, so a
///   late `@dev` cannot silently route to a different agent that reused the
///   name;
/// * `all` and `coordinator` are session-reserved broadcast destinations: they
///   are never assigned to an agent, they stay reserved across a session reset,
///   and an agent whose display name collides with one is disambiguated to
///   `all-2` / `coordinator-2` so `@all` and `@coordinator` keep their
///   broadcast meaning for the whole session;
/// * duplicate display names are disambiguated with a numeric suffix
///   (`dev`, `dev-2`, `dev-3`) assigned deterministically;
/// * display names are sanitised before they become handles, so a name carrying
///   whitespace, punctuation or control characters cannot produce an
///   unparseable or hostile handle; a name that yields no ASCII slug falls back
///   to the stable readable handle `agent`, never to the participant id or a
///   UUID, so no internal identifier is ever exposed in a visible handle;
/// * the handle map only covers live `.agent` participants (`isActive ==
///   true`), so inactive agents and coordinator/operator entries never appear
///   in autocomplete or in parser routing;
/// * a session reset clears every mapping and every ordinary reserved alias,
///   but keeps the session-reserved `all` and `coordinator` handles, so a new
///   session starts from a clean alias space without ever reopening the
///   broadcast spellings;
/// * the legacy `@agent-Base64` spelling is still accepted by the parser for
///   backward compatibility, but is never offered by the autocomplete list.
public actor SharedChatMentionCatalog {
    /// One handle can grow this long at most. It keeps a hostile display name
    /// from producing a multi-kilobyte `@handle` while leaving plenty of room
    /// for readable, descriptive aliases.
    static let maximumHandleLength = 48

    /// Broadcast destinations reserved for the entire session. They are never
    /// assigned to an agent and survive a session reset, so `@all` and
    /// `@coordinator` always keep their reserved meaning.
    static let sessionReservedHandles: Set<String> = ["all", "coordinator"]

    private var handleToParticipantID: [String: String] = [:]
    private var participantIDToHandle: [String: String] = [:]
    /// Every handle ever assigned in this session, even after its owner left,
    /// plus the session-reserved broadcast destinations. Reserved so aliases
    /// are never recycled.
    private var reservedHandles: Set<String>

    public init() {
        reservedHandles = Self.sessionReservedHandles
    }

    /// Returns the readable handle for `participant`, assigning a fresh one if
    /// this participant has no handle yet. A returning participant (same id)
    /// keeps its existing handle.
    func handle(for participant: AgentSharedChat.Participant) -> String {
        if let existing = participantIDToHandle[participant.id] {
            return existing
        }
        let base = Self.sanitizedBaseHandle(from: participant.name)
        let handle = Self.uniqueHandle(base: base, reserved: reservedHandles)
        reservedHandles.insert(handle)
        participantIDToHandle[participant.id] = handle
        handleToParticipantID[handle] = participant.id
        return handle
    }

    /// Resolves a readable handle back to its stable participant id, or nil if
    /// no live mapping exists.
    func participantID(forHandle handle: String) -> String? {
        handleToParticipantID[handle]
    }

    /// Builds a handle → participant-id map for a batch of participants,
    /// assigning handles as needed. Only live `.agent` participants
    /// (`kind == .agent && isActive`) are covered: inactive agents and
    /// coordinator/operator entries get no handle, no suggestion and no parser
    /// route. Used by the autocomplete list and the mention parser.
    func handleMap(
        for participants: [AgentSharedChat.Participant]
    ) -> [String: String] {
        var map: [String: String] = [:]
        for participant in participants where participant.kind == .agent && participant.isActive {
            let handle = self.handle(for: participant)
            map[handle] = participant.id
        }
        return map
    }

    /// Clears every mapping and releases every ordinary reserved alias. Called
    /// on session reset so a new session starts from a clean alias space. The
    /// session-reserved `all` and `coordinator` handles are kept: they belong
    /// to the session itself, not to a particular roster, so `@all` and
    /// `@coordinator` can never be captured by a future agent.
    func reset() {
        handleToParticipantID.removeAll()
        participantIDToHandle.removeAll()
        reservedHandles = Self.sessionReservedHandles
    }

    // MARK: - Sanitisation

    /// Produces a deterministic, terminal-safe base handle from a display name.
    /// A name whose slug is empty (Unicode-only, bidi-only, punctuation-only or
    /// blank) falls back to the stable readable handle `agent`. The participant
    /// id is deliberately never used as a fallback: an internal identifier or
    /// UUID must never surface as a visible handle.
    static func sanitizedBaseHandle(from name: String) -> String {
        // Neutralise control/bidi characters first, then build an ASCII-safe
        // slug from the surviving letters and digits.
        let neutralised = AgentSharedChat.sanitizedHandleSlug(name)
        guard !neutralised.isEmpty else {
            return "agent"
        }
        return String(neutralised.prefix(maximumHandleLength))
    }

    /// Returns a handle not present in `reserved`, appending a numeric suffix
    /// (separated by a dash) when the base is already taken. The search is
    /// deterministic and never fabricates an id or UUID: suffixes grow until a
    /// free candidate is found, and the finite reserved set guarantees
    /// termination.
    static func uniqueHandle(base: String, reserved: Set<String>) -> String {
        guard !reserved.contains(base) else {
            var suffix = 2
            while true {
                let suffixString = "-\(suffix)"
                let candidate = "\(base)\(suffixString)"
                if candidate.count > maximumHandleLength {
                    let overflow = maximumHandleLength - suffixString.count
                    let trimmedBase = String(base.prefix(max(1, overflow)))
                    let trimmed = "\(trimmedBase)\(suffixString)"
                    if !reserved.contains(trimmed) {
                        return trimmed
                    }
                } else if !reserved.contains(candidate) {
                    return candidate
                }
                suffix += 1
            }
        }
        return base
    }
}
