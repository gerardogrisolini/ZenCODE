//
//  DS4SessionPool.swift
//  ZenCODE
//
//  Per-engine map ZenCODE sessionID -> live DS4 session handle with LRU
//  eviction. Generic over the handle so it is testable without C
//  (`DS4NativeEngine` uses it with `void *` session handles on its engine
//  thread; `MockDS4Engine` with fake handles). Not thread-safe: the owner
//  serializes access.
//
//  Rules
//  - Sessions are created lazily by `acquire` (sync / checkpoint load).
//  - At most `capacity` sessions are live; creating one more evicts the least
//    recently used session (the caller frees its handle). The evicted
//    session is rebuilt from the common prefix at its next sync.
//  - The pinned session (last successful sync / load, until its generate
//    returns) is skipped by LRU and evicted only when it is the sole
//    candidate: under the generation lease that means its turn is over.
//  - Power / steering settings are remembered per sessionID, survive
//    eviction (reapplied to the recreated session) and are dropped by
//    `remove` (session released).
//

/// Per-session evaluation settings reapplied when a session is recreated.
struct DS4SessionSettings: Sendable, Hashable {
    var powerPercent: Int?
    var steeringFFNScale: Double?

    var isEmpty: Bool {
        powerPercent == nil && steeringFFNScale == nil
    }
}

struct DS4SessionPool<Handle> {
    let capacity: Int

    private struct Entry {
        let handle: Handle
        var lastUse: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var settings: [String: DS4SessionSettings] = [:]
    private var clock: UInt64 = 0
    private(set) var pinnedSessionID: String?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        entries.count
    }

    /// Live session IDs, least recently used first.
    var sessionIDsByRecency: [String] {
        entries.sorted { $0.value.lastUse < $1.value.lastUse }.map(\.key)
    }

    func contains(_ sessionID: String) -> Bool {
        entries[sessionID] != nil
    }

    /// Handle of a live session without touching its recency.
    func peekHandle(for sessionID: String) -> Handle? {
        entries[sessionID]?.handle
    }

    /// Handle of a live session (marks it as recently used).
    mutating func existingHandle(for sessionID: String) -> Handle? {
        guard var entry = entries[sessionID] else {
            return nil
        }
        clock += 1
        entry.lastUse = clock
        entries[sessionID] = entry
        return entry.handle
    }

    /// Returns the live handle of `sessionID`, or creates one: evicts the LRU
    /// session first when the pool is full (`free` releases its handle),
    /// then calls `create` and `configure` with the remembered settings (when
    /// any). A failing `configure` frees the new handle and rethrows.
    mutating func acquire(
        _ sessionID: String,
        create: () throws -> Handle,
        configure: (Handle, DS4SessionSettings) throws -> Void,
        free: (_ sessionID: String, _ handle: Handle) -> Void
    ) throws -> (handle: Handle, created: Bool) {
        if let handle = existingHandle(for: sessionID) {
            return (handle, false)
        }
        while entries.count >= capacity, let victim = evictionCandidate(excluding: sessionID) {
            if let entry = entries.removeValue(forKey: victim) {
                if pinnedSessionID == victim {
                    pinnedSessionID = nil
                }
                free(victim, entry.handle)
            }
        }
        let handle = try create()
        if let stored = settings[sessionID], !stored.isEmpty {
            do {
                try configure(handle, stored)
            } catch {
                free(sessionID, handle)
                throw error
            }
        }
        clock += 1
        entries[sessionID] = Entry(handle: handle, lastUse: clock)
        return (handle, true)
    }

    /// LRU session other than `sessionID`, preferring unpinned ones.
    func evictionCandidate(excluding sessionID: String) -> String? {
        let candidates = entries.filter { $0.key != sessionID }
        let unpinned = candidates.filter { $0.key != pinnedSessionID }
        let pool = unpinned.isEmpty ? candidates : unpinned
        return pool.min { $0.value.lastUse < $1.value.lastUse }?.key
    }

    mutating func pin(_ sessionID: String) {
        pinnedSessionID = sessionID
    }

    /// Clears the pin when it is `sessionID`.
    mutating func unpin(_ sessionID: String) {
        if pinnedSessionID == sessionID {
            pinnedSessionID = nil
        }
    }

    func settings(for sessionID: String) -> DS4SessionSettings {
        settings[sessionID] ?? DS4SessionSettings()
    }

    mutating func updateSettings(for sessionID: String, _ update: (inout DS4SessionSettings) -> Void) {
        var value = settings[sessionID] ?? DS4SessionSettings()
        update(&value)
        settings[sessionID] = value.isEmpty ? nil : value
    }

    /// Removes the session (released for good): returns its handle, when
    /// live, for the caller to free, and forgets its settings.
    mutating func remove(_ sessionID: String) -> Handle? {
        settings[sessionID] = nil
        unpin(sessionID)
        return entries.removeValue(forKey: sessionID)?.handle
    }

    /// Removes every session and setting; returns the live handles.
    mutating func removeAll() -> [Handle] {
        let handles = sessionIDsByRecency.compactMap { entries[$0]?.handle }
        entries.removeAll()
        settings.removeAll()
        pinnedSessionID = nil
        return handles
    }
}
