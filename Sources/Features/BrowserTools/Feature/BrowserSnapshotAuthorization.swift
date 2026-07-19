//
//  BrowserSnapshotAuthorization.swift
//  BrowserToolsFeature
//
//  Browser-owned authorization for opaque accessibility refs. This state never
//  enters the page's JavaScript realm: it is retained in Browser's private
//  host-side profile and is invalidated when the main-frame document changes.
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Identifies the current main-frame document without relying on page-provided
/// JavaScript state. A same-document history change keeps its loader, whereas a
/// document navigation receives a new loader identity.
struct BrowserDocumentIdentity: Codable, Hashable, Sendable {
    let frameID: String
    let loaderID: String

    static func parse(_ response: [String: Any]) throws -> Self {
        guard let result = response["result"] as? [String: Any],
              let frameTree = result["frameTree"] as? [String: Any],
              let frame = frameTree["frame"] as? [String: Any],
              let frameID = nonBlankString(frame["id"]),
              let loaderID = nonBlankString(frame["loaderId"])
        else {
            throw CDPError.invalidResponse(
                "Page.getFrameTree did not return a main-frame loader identity"
            )
        }
        return Self(frameID: frameID, loaderID: loaderID)
    }

    private static func nonBlankString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Immutable authorization context passed through snapshot-bound operations.
/// `ref == nil` is used only by `browser.act`'s keyboard action, which still
/// requires a current snapshot for its page but does not resolve an element.
struct BrowserSnapshotAuthorization: Sendable {
    let pageID: String
    let snapshotID: String
    let ref: String?

    init(pageID: String, snapshotID: String, ref: String?) {
        self.pageID = pageID
        self.snapshotID = snapshotID
        self.ref = ref
    }
}

/// Host-side limits cap the durable authorization state independently of the
/// snapshot output budget. A fresh snapshot atomically replaces the previous
/// authorization for the same page.
enum BrowserSnapshotAuthorizationLimits {
    static let maximumTrackedPages = 64
    static let maximumRefsPerSnapshot = 512
    static let maximumPageIDBytes = 512
    static let maximumSnapshotIDBytes = 128
    static let maximumRefBytes = 512
    static let maximumDocumentIdentityBytes = 512
    static let maximumStateBytes = 512 * 1024
}

private enum BrowserSnapshotStateStoreError: LocalizedError {
    case unavailable
    case stateTooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Browser could not access its private snapshot authorization state. Take a fresh browser.snapshot and retry."
        case .stateTooLarge:
            "Browser snapshot authorization exceeded its fixed host-side state budget."
        }
    }
}

/// A bounded host-side store shared by the feature's one-shot processes. Chrome
/// pages deliberately outlive one tool executable, so an in-memory/global state
/// would not preserve snapshot authorization across `browser.snapshot` and
/// `browser.act`. Records live only in Browser's private profile, never in a
/// page, `globalThis`, `UserDefaults`, or model-controlled path.
///
/// Every read-modify-write operation takes an interprocess `flock` on a stable
/// sibling lock file and writes JSON atomically. The lock is separate from the
/// data file so `Data.write(.atomic)` may replace the data inode without losing
/// the serialization guarantee.
struct BrowserSnapshotStateStore: Sendable {
    private struct Record: Codable, Sendable {
        let snapshotID: String
        let allowedRefs: [String]
        let document: BrowserDocumentIdentity
    }

    private struct State: Codable, Sendable {
        var recordsByPageID: [String: Record]
        /// Least-recently-recorded page first. It is persisted so the bounded
        /// eviction policy remains stable across one-shot feature processes.
        var pageOrder: [String]

        static let empty = State(recordsByPageID: [:], pageOrder: [])
    }

    /// `flock` coordinates processes; this lock additionally serializes two
    /// store instances created by concurrent tasks within one feature process.
    private static let localLock = NSLock()

    private let stateURL: URL
    private let lockURL: URL
    private let maximumPageCount: Int
    private let maximumRefsPerSnapshot: Int

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stateURL: URL? = nil,
        maximumPageCount: Int = BrowserSnapshotAuthorizationLimits.maximumTrackedPages,
        maximumRefsPerSnapshot: Int = BrowserSnapshotAuthorizationLimits.maximumRefsPerSnapshot
    ) {
        let resolvedStateURL = stateURL ?? ChromeBrowserConfiguration(environment: environment)
            .profileDirectory
            .appendingPathComponent("snapshot-authorizations.json", isDirectory: false)
        self.stateURL = resolvedStateURL
        self.lockURL = resolvedStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("snapshot-authorizations.lock", isDirectory: false)
        self.maximumPageCount = max(1, maximumPageCount)
        self.maximumRefsPerSnapshot = max(1, maximumRefsPerSnapshot)
    }

    /// Atomically replaces the page's previous authorization record. Inputs
    /// are host-generated/captured but are still bounded at the durable-state
    /// boundary before they survive a one-shot feature invocation.
    @discardableResult
    func record(
        pageID: String,
        snapshotID: String,
        allowedRefs: [String],
        document: BrowserDocumentIdentity
    ) throws -> Bool {
        guard Self.isValidPageID(pageID),
              Self.isWithinLimit(snapshotID, limit: BrowserSnapshotAuthorizationLimits.maximumSnapshotIDBytes),
              Self.isWithinLimit(document.frameID, limit: BrowserSnapshotAuthorizationLimits.maximumDocumentIdentityBytes),
              Self.isWithinLimit(document.loaderID, limit: BrowserSnapshotAuthorizationLimits.maximumDocumentIdentityBytes),
              allowedRefs.count <= maximumRefsPerSnapshot,
              allowedRefs.allSatisfy({ Self.isWithinLimit($0, limit: BrowserSnapshotAuthorizationLimits.maximumRefBytes) })
        else {
            return false
        }

        let refs = Array(Set(allowedRefs)).sorted()
        guard refs.count <= maximumRefsPerSnapshot else { return false }

        return try withExclusiveLock {
            var state = readState()
            state.recordsByPageID[pageID] = Record(
                snapshotID: snapshotID,
                allowedRefs: refs,
                document: document
            )
            touch(pageID: pageID, in: &state)
            trim(&state, preserving: pageID)
            guard fitsStateBudget(state) else { return false }
            try writeState(state)
            return true
        }
    }

    /// Validates the opaque nonce, optional ref, and current main document in
    /// one locked transaction. A document mismatch removes the stale record so
    /// a back/forward restoration cannot re-enable an authorization issued for
    /// a previous navigation.
    func isAuthorized(
        pageID: String,
        snapshotID: String,
        ref: String?,
        document: BrowserDocumentIdentity
    ) throws -> Bool {
        guard Self.isValidPageID(pageID),
              Self.isWithinLimit(snapshotID, limit: BrowserSnapshotAuthorizationLimits.maximumSnapshotIDBytes),
              ref.map({ Self.isWithinLimit($0, limit: BrowserSnapshotAuthorizationLimits.maximumRefBytes) }) ?? true
        else {
            return false
        }

        return try withExclusiveLock {
            var state = readState()
            guard let record = state.recordsByPageID[pageID] else { return false }
            guard record.document == document else {
                state.recordsByPageID.removeValue(forKey: pageID)
                state.pageOrder.removeAll { $0 == pageID }
                try writeState(state)
                return false
            }
            guard record.snapshotID == snapshotID else { return false }
            guard let ref else { return true }
            return record.allowedRefs.contains(ref)
        }
    }

    func remove(pageID: String) throws {
        guard Self.isValidPageID(pageID) else { return }
        try withExclusiveLock {
            var state = readState()
            guard state.recordsByPageID.removeValue(forKey: pageID) != nil else { return }
            state.pageOrder.removeAll { $0 == pageID }
            try writeState(state)
        }
    }

    func recordCount() throws -> Int {
        try withExclusiveLock {
            readState().recordsByPageID.count
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        Self.localLock.lock()
        defer { Self.localLock.unlock() }

        let directory = stateURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw BrowserSnapshotStateStoreError.unavailable
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw BrowserSnapshotStateStoreError.unavailable
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw BrowserSnapshotStateStoreError.unavailable
        }
        #if canImport(Darwin) || canImport(Glibc)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: lockURL.path
        )
        #endif
        return try body()
    }

    /// Disk state is treated as untrusted. Invalid or oversized JSON produces
    /// an empty state (all old snapshots fail closed), never an implicit grant.
    private func readState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              data.count <= BrowserSnapshotAuthorizationLimits.maximumStateBytes,
              let decoded = try? JSONDecoder().decode(State.self, from: data)
        else {
            return .empty
        }
        return sanitized(decoded)
    }

    private func writeState(_ state: State) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            throw BrowserSnapshotStateStoreError.unavailable
        }
        guard data.count <= BrowserSnapshotAuthorizationLimits.maximumStateBytes else {
            throw BrowserSnapshotStateStoreError.stateTooLarge
        }
        do {
            try data.write(to: stateURL, options: .atomic)
            #if canImport(Darwin) || canImport(Glibc)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateURL.path
            )
            #endif
        } catch {
            throw BrowserSnapshotStateStoreError.unavailable
        }
    }

    private func sanitized(_ rawState: State) -> State {
        var records: [String: Record] = [:]
        for pageID in rawState.recordsByPageID.keys.sorted() {
            guard let record = rawState.recordsByPageID[pageID],
                  Self.isValidPageID(pageID),
                  Self.isValidRecord(record, maximumRefsPerSnapshot: maximumRefsPerSnapshot)
            else {
                continue
            }
            records[pageID] = Record(
                snapshotID: record.snapshotID,
                allowedRefs: Array(Set(record.allowedRefs)).sorted(),
                document: record.document
            )
        }

        var seen = Set<String>()
        var order: [String] = []
        for pageID in rawState.pageOrder where records[pageID] != nil && seen.insert(pageID).inserted {
            order.append(pageID)
        }
        for pageID in records.keys.sorted() where seen.insert(pageID).inserted {
            order.append(pageID)
        }

        var state = State(recordsByPageID: records, pageOrder: order)
        trim(&state, preserving: nil)
        // If a locally modified file holds unusually long but individually
        // valid values, fail closed by discarding it rather than retaining an
        // unbounded authorization channel.
        return fitsStateBudget(state) ? state : .empty
    }

    private func touch(pageID: String, in state: inout State) {
        state.pageOrder.removeAll { $0 == pageID }
        state.pageOrder.append(pageID)
    }

    private func trim(_ state: inout State, preserving pageID: String?) {
        while state.recordsByPageID.count > maximumPageCount {
            guard let candidate = state.pageOrder.first else {
                state.recordsByPageID.removeAll()
                return
            }
            state.pageOrder.removeFirst()
            if candidate == pageID, state.recordsByPageID.count > 1 {
                state.pageOrder.append(candidate)
                continue
            }
            state.recordsByPageID.removeValue(forKey: candidate)
        }

        // A bounded byte budget is independent of count. Evict oldest pages
        // until the encoded state fits, never evicting a just-recorded page if
        // another record can be removed instead.
        while !fitsStateBudget(state), state.recordsByPageID.count > 1 {
            guard let candidate = state.pageOrder.first else { break }
            state.pageOrder.removeFirst()
            if candidate == pageID {
                state.pageOrder.append(candidate)
                continue
            }
            state.recordsByPageID.removeValue(forKey: candidate)
        }
    }

    private func fitsStateBudget(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return data.count <= BrowserSnapshotAuthorizationLimits.maximumStateBytes
    }

    private static func isValidRecord(
        _ record: Record,
        maximumRefsPerSnapshot: Int
    ) -> Bool {
        Self.isWithinLimit(record.snapshotID, limit: BrowserSnapshotAuthorizationLimits.maximumSnapshotIDBytes)
            && Self.isWithinLimit(record.document.frameID, limit: BrowserSnapshotAuthorizationLimits.maximumDocumentIdentityBytes)
            && Self.isWithinLimit(record.document.loaderID, limit: BrowserSnapshotAuthorizationLimits.maximumDocumentIdentityBytes)
            && record.allowedRefs.count <= maximumRefsPerSnapshot
            && record.allowedRefs.allSatisfy {
                Self.isWithinLimit($0, limit: BrowserSnapshotAuthorizationLimits.maximumRefBytes)
            }
    }

    private static func isValidPageID(_ value: String) -> Bool {
        guard isWithinLimit(value, limit: BrowserSnapshotAuthorizationLimits.maximumPageIDBytes) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func isWithinLimit(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.lengthOfBytes(using: .utf8) <= limit
    }
}
