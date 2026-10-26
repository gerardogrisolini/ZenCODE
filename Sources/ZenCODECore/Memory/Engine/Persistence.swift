//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

protocol MemoryPersistence: Sendable {
    func load() async throws -> MemoryGraph
    func save(_ graph: MemoryGraph) async throws
}

/// Optional stronger persistence contract for stores shared by independent
/// ZenCODE processes. The closure is deliberately synchronous: it executes
/// while the durable store's exclusive lock is held, so loading, mutation and
/// atomic replacement form one read-modify-write transaction.
protocol MemoryTransactionalPersistence: MemoryPersistence {
    func transaction<T: Sendable>(
        initialGraph: MemoryGraph?,
        _ body: @Sendable (inout MemoryGraph) throws -> T
    ) async throws -> (result: T, graph: MemoryGraph, didChange: Bool)
}

/// A persistence that can refresh an already-open engine without performing
/// the permission hardening and other ownership work associated with `load()`.
/// This contract is intentionally separate: only implementations that can
/// guarantee a side-effect-free reload participate in fresh store reads.
protocol MemoryReadOnlyReloadPersistence: MemoryTransactionalPersistence {
    func reloadReadOnly() async throws -> MemoryGraph
}

enum MemoryPersistenceError: Error, Sendable, Equatable {
    /// The graph file was written by a newer engine than this build supports.
    /// The file is rejected and left byte-identical on disk.
    case unsupportedGraphVersion(UInt32)
}

/// Date coding used by the graph persistence format.
///
/// Foundation's built-in `.iso8601` encoder emits whole seconds (and
/// `ISO8601DateFormatter` with `.withFractionalSeconds` is limited to
/// milliseconds on some platforms). A graph mutation can therefore reload a
/// `Date` under the persistence lock with its subsecond component truncated.
/// Keep the existing ISO-8601 string schema, but write a nanosecond fraction so
/// a normal `Date` round-trip remains exact. The decoder deliberately accepts
/// both the old whole-second representation and fractional representations.
private enum MemoryJSONDateCoding {
    static func encodingStrategy() -> JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
    }

    static func decodingStrategy() -> JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = fractionalDate(from: value) {
                return date
            }

            if let date = try? Date.ISO8601FormatStyle(
                includingFractionalSeconds: true
            ).parse(value) {
                return date
            }

            // Keep a Foundation formatter fallback for ISO-8601 spellings
            // accepted by older `.iso8601` implementations but not by the
            // value-type parser on every supported platform.
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date string."
            )
        }
    }

    /// Parses a fractional ISO-8601 value by adding the fraction to the
    /// already-decoded whole-second `Date`. Doing the addition at Date's
    /// reference-epoch magnitude avoids the one-ULP drift that can occur when
    /// a Unix-epoch `Double` is formed first and the reference offset is later
    /// subtracted by Foundation.
    private static func fractionalDate(from value: String) -> Date? {
        guard let decimalPoint = value.firstIndex(of: ".") else { return nil }
        let suffix = value[decimalPoint...]
        guard let zoneStart = suffix.firstIndex(where: { character in
            character == "Z" || character == "+" || character == "-"
        }) else {
            return nil
        }

        let fractionStart = value.index(after: decimalPoint)
        guard fractionStart < zoneStart else { return nil }
        let fractionText = value[fractionStart..<zoneStart]
        guard fractionText.allSatisfy(\.isNumber),
              let fraction = Double("0." + fractionText) else {
            return nil
        }

        let wholeSecondsText = String(value[..<decimalPoint]) + String(value[zoneStart...])
        guard let wholeDate = try? Date.ISO8601FormatStyle().parse(wholeSecondsText) else {
            return nil
        }
        return wholeDate.addingTimeInterval(fraction)
    }

    private static func string(from date: Date) -> String {
        // Date's internal reference epoch (2001-01-01) is deliberately used
        // for the split. It has a smaller magnitude than Unix seconds, so the
        // fraction survives the later ISO calendar conversion without an ULP
        // changing the reconstructed Date.
        var wholeSeconds = floor(date.timeIntervalSinceReferenceDate)
        var nanoseconds = Int(
            ((date.timeIntervalSinceReferenceDate - wholeSeconds) * 1_000_000_000).rounded()
        )
        if nanoseconds >= 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }

        // Formatting the integral second through Foundation keeps calendar,
        // leap-year and pre-epoch handling in the standard implementation.
        let base = Date(timeIntervalSinceReferenceDate: wholeSeconds).ISO8601Format()
        let fraction = String(nanoseconds)
        let paddedFraction = String(repeating: "0", count: 9 - fraction.count) + fraction
        return String(base.dropLast()) + "." + paddedFraction + "Z"
    }
}

actor JSONMemoryPersistence: MemoryReadOnlyReloadPersistence {
    public let url: URL

    /// Identity of the file an in-memory decode was taken from. The graph is
    /// only ever published by renaming a freshly written staging file, so a
    /// changed graph always changes the inode; size and modification time
    /// additionally cover a foreign writer that rewrote the inode in place.
    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationNanoseconds: Int64
    }

    /// The last decoded graph and the identity of the file it came from.
    /// Every read path reuses it while the file is unchanged, so a large graph
    /// is decoded once per change instead of once per read, recall or
    /// transaction; a publish re-primes it from the bytes it just wrote. The
    /// cache only ever shortcuts the decode: what a read returns is exactly
    /// what decoding the current file would return.
    private var cached: (identity: FileIdentity, graph: MemoryGraph)?

    /// Number of graphs decoded from disk. Test seam only.
    private(set) var diskDecodeCount = 0

    public init(url: URL) {
        self.url = url
    }

    public func load() async throws -> MemoryGraph {
        // Opening is the moment a pre-existing store becomes this process's
        // responsibility, so it is also where a graph, lock or directory left
        // group/other-readable by an older build (or a permissive umask) is
        // tightened. Best effort on purpose: a read must not start failing
        // because the mode of a file owned by another user cannot be changed.
        Self.hardenExistingItems(graphURL: url, lockURL: lockURL)
        return try loadSynchronously()
    }

    /// Reloads the graph without chmod, directory creation, lock creation or
    /// any other filesystem mutation. Opening retains the hardening behavior in
    /// `load()`; request-time freshness is a strictly read-only operation.
    func reloadReadOnly() async throws -> MemoryGraph {
        try loadSynchronously()
    }

    public func save(_ graph: MemoryGraph) async throws {
        try withExclusiveFileLock {
            try saveSynchronously(graph)
        }
    }

    /// Performs a full transaction while holding a separate, stable lock file.
    /// Locking `url` itself would be ineffective because `Data.WritingOptions.atomic`
    /// replaces that inode on every save. The adjacent lock inode is never
    /// replaced, so `flock` coordinates macOS and Linux processes correctly.
    public func transaction<T: Sendable>(
        initialGraph: MemoryGraph? = nil,
        _ body: @Sendable (inout MemoryGraph) throws -> T
    ) async throws -> (result: T, graph: MemoryGraph, didChange: Bool) {
        try withExclusiveFileLock {
            // An initial graph can live only in the engine until its first
            // mutation. Seed only a genuinely absent file; once any process has
            // committed, always reload that durable graph under this lock.
            var graph = if FileManager.default.fileExists(atPath: url.path) {
                try loadSynchronously()
            } else {
                initialGraph ?? MemoryGraph()
            }
            let original = graph
            let result = try body(&graph)
            let didChange = graph != original
            if didChange {
                // Last controllable boundary before the graph becomes durable.
                // The body may have run long (revalidation, replay of pending
                // recall maintenance) and its caller's deadline may have passed
                // in the meantime; publishing here would make an abandoned turn
                // durable. Throwing *before* the write keeps the transaction
                // all-or-nothing: nothing is written and the caller's in-memory
                // state is left untouched. There is deliberately no failable
                // step after the write.
                try Task.checkCancellation()
                try saveSynchronously(graph)
            }
            return (result, graph, didChange)
        }
    }

    private var lockURL: URL {
        url.appendingPathExtension("lock")
    }

    private func loadSynchronously() throws -> MemoryGraph {
        guard let before = try Self.identity(ofFileAt: url.path) else {
            // No file: nothing to decode and nothing worth keeping.
            cached = nil
            return MemoryGraph()
        }
        if let cached, cached.identity == before {
            return cached.graph
        }
        let data = try Data(contentsOf: url)
        diskDecodeCount += 1
        let graph = try decodeGraph(data)
        // A publish between the identity check and the read would pair one
        // file's identity with another file's bytes. Keep the pair only when
        // the file did not change across the read; under the lock it never
        // does, and an unlocked read simply decodes again next time.
        if let after = try? Self.identity(ofFileAt: url.path), after == before {
            cached = (before, graph)
        } else {
            cached = nil
        }
        return graph
    }

    /// `nil` when no file exists at `path`. Read through `attributesOfItem`,
    /// which reports device, inode, size and the nanosecond modification time
    /// on Darwin and Linux without naming `struct stat`, whose defining Clang
    /// module is not stable under `MemberImportVisibility` on Linux.
    private static func identity(ofFileAt path: String) throws -> FileIdentity? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileIdentity(
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationNanoseconds: Int64((modified * 1_000_000_000).rounded())
        )
    }

    /// Decodes a persisted graph without writing it. Both ordinary loads and
    /// locked transactions use this single path, preserving future-version
    /// rejection and lazy in-memory normalization identically.
    private func decodeGraph(_ data: Data) throws -> MemoryGraph {
        // Reject future formats before attempting a full decode: the schema may
        // have changed in ways this build cannot interpret. This path never
        // writes, so rejecting here keeps the file byte-identical.
        let envelopeDecoder = JSONDecoder()
        envelopeDecoder.keyDecodingStrategy = .convertFromSnakeCase
        if let envelope = try? envelopeDecoder.decode(GraphVersionEnvelope.self, from: data),
           let version = envelope.graphVersion,
           version > MemoryGraph.currentGraphVersion {
            throw MemoryPersistenceError.unsupportedGraphVersion(version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MemoryJSONDateCoding.decodingStrategy()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var graph = try decoder.decode(MemoryGraph.self, from: data)
        graph.rebuildReverseEdges()

        // Older versions (or files without an explicit version) are decoded by
        // the current schema: every newer field is optional with a contract
        // default (`scope` -> `.project`, `active` -> `true`, ...). Normalize
        // the in-memory version to the current one so the next save writes the
        // current format; the on-disk file is only rewritten by an explicit
        // save, never by loading.
        if graph.graphVersion < MemoryGraph.currentGraphVersion {
            graph.graphVersion = MemoryGraph.currentGraphVersion
        }
        return graph
    }

    /// The persisted wire form of a graph: ISO-8601 dates with a nanosecond
    /// fraction, snake_case keys, sorted and pretty-printed. The single place
    /// that configures the encoder, shared by saves and backups.
    static func encodeGraph(_ graph: MemoryGraph) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = MemoryJSONDateCoding.encodingStrategy()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(graph)
    }

    /// Writes `graph` in the persisted format to `url` through the same owner-only
    /// staging file and `rename` as a save: an existing copy is replaced
    /// atomically and a partial copy is never visible. Touches neither the
    /// store's reload cache nor its lock, so it is meant for a caller that
    /// already holds the transaction (a copy taken before the graph is changed).
    static func writeBackup(of graph: MemoryGraph, to url: URL) throws {
        _ = try publishPrivately(encodeGraph(graph), to: url)
    }

    private func saveSynchronously(_ graph: MemoryGraph) throws {
        let directory = url.deletingLastPathComponent()
        try Self.prepareOwnerOnlyDirectory(directory)
        // Byte-identical payload to every previous version of this method; only
        // the way it reaches the final path changed.
        let data = try Self.encodeGraph(graph)
        let identity = try Self.publishPrivately(data, to: url)
        // Re-prime from the bytes just published, so the next read — typically
        // the next turn's recall — pays no decode. Decoding what this build has
        // just encoded cannot fail; should it ever, the cache is dropped rather
        // than reporting an error for an already-durable graph.
        if let published = try? decodeGraph(data) {
            cached = (identity, published)
        } else {
            cached = nil
        }
    }

    /// Installs `data` at `url` through an owner-only staging file and returns
    /// the identity of the published inode.
    ///
    /// `Data.WritingOptions.atomic` also stages and renames, but it creates the
    /// staged file with the process umask and replaces the inode, so the graph
    /// exists — however briefly — with whatever mode the umask allowed, and the
    /// mode can only be corrected *after* the content is already published.
    /// Staging by hand makes the file private *before* a single byte of graph
    /// content is written and publishes it with `rename`, which is atomic within
    /// the directory. `rename` is the commit point and nothing failable follows
    /// it, so this never reports an error for an already-durable graph. The
    /// identity is taken from the private staging file before the rename,
    /// which preserves it: it is the published inode's identity whatever
    /// another writer does afterwards.
    static func publishPrivately(_ data: Data, to url: URL) throws -> FileIdentity {
        let directory = url.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).staging"
        )
        let descriptor = open(staging.path, O_CREAT | O_WRONLY | O_TRUNC | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw errnoError() }
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: staging) }
        }
        let publishedIdentity: FileIdentity
        do {
            // `open`'s mode argument is masked by the umask, which can only
            // clear bits — never add them — but an inherited restrictive umask
            // would otherwise make the published mode unpredictable. Pin it
            // while the file is still empty.
            guard fchmod(descriptor, 0o600) == 0 else { throw errnoError() }
            try writeFully(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw errnoError() }
        } catch {
            _ = close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else { throw errnoError() }
        guard let stagedIdentity = try identity(ofFileAt: staging.path) else {
            throw POSIXError(.ENOENT)
        }
        publishedIdentity = stagedIdentity
        // `rename` publishes the completed private staging inode. Check as
        // close to that commit point as possible so a cancellation observed
        // after I/O never makes an abandoned operation visible.
        try Task.checkCancellation()
        guard rename(staging.path, url.path) == 0 else { throw errnoError() }
        published = true
        return publishedIdentity
    }

    private static func writeFully(_ data: Data, to descriptor: Int32) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw errnoError()
                }
                offset += written
            }
        }
    }

    /// Creates the graph directory owner-only, or tightens an existing one.
    private static func prepareOwnerOnlyDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return
        }
        restrictIfPermissive(directory, to: 0o700)
    }

    /// Tightens whatever already exists, without ever widening a mode.
    ///
    /// Used on the read paths (`load`) and when the lock is taken, so a store
    /// created by an older build stops being group/other-readable at the first
    /// touch instead of only at the first write.
    private static func hardenExistingItems(graphURL: URL, lockURL: URL) {
        let directory = graphURL.deletingLastPathComponent()
        restrictIfPermissive(directory, to: 0o700)
        restrictIfPermissive(graphURL, to: 0o600)
        restrictIfPermissive(lockURL, to: 0o600)
    }

    /// Clears every mode bit outside `allowed`. Never adds a bit, never throws:
    /// a store that cannot be tightened (foreign owner, read-only mount) must
    /// still be readable.
    @discardableResult
    private static func restrictIfPermissive(_ url: URL, to allowed: Int) -> Bool {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let current = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            return false
        }
        let restricted = current & allowed
        guard restricted != current else { return false }
        return (try? fileManager.setAttributes(
            [.posixPermissions: restricted],
            ofItemAtPath: url.path
        )) != nil
    }

    private static func errnoError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func withExclusiveFileLock<T>(_ body: () throws -> T) throws -> T {
        try Self.prepareOwnerOnlyDirectory(lockURL.deletingLastPathComponent())
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw Self.errnoError() }
        defer { _ = close(descriptor) }
        // `open(..., 0600)` only governs creation, so a lock file left
        // group/other-writable by an older build keeps that mode. Tighten it
        // here too; like every other upgrade this is best effort and never
        // turns a permission quirk into a failed memory operation.
        Self.restrictIfPermissive(lockURL, to: 0o600)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw Self.errnoError()
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Minimal envelope used only to read `graph_version` before full decoding.
    private struct GraphVersionEnvelope: Decodable {
        let graphVersion: UInt32?
    }
}
