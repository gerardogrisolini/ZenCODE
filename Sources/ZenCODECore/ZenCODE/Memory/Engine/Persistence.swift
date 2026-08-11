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

actor JSONMemoryPersistence: MemoryTransactionalPersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() async throws -> MemoryGraph {
        guard FileManager.default.fileExists(atPath: url.path) else { return MemoryGraph() }
        return try decodeGraph(Data(contentsOf: url))
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
            // A lazy legacy migration lives only in the engine until its first
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
                try saveSynchronously(graph)
            }
            return (result, graph, didChange)
        }
    }

    private var lockURL: URL {
        url.appendingPathExtension("lock")
    }

    private func loadSynchronously() throws -> MemoryGraph {
        guard FileManager.default.fileExists(atPath: url.path) else { return MemoryGraph() }

        return try decodeGraph(Data(contentsOf: url))
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

    private func saveSynchronously(_ graph: MemoryGraph) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = MemoryJSONDateCoding.encodingStrategy()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(graph).write(to: url, options: .atomic)
    }

    private func withExclusiveFileLock<T>(_ body: () throws -> T) throws -> T {
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Minimal envelope used only to read `graph_version` before full decoding.
    private struct GraphVersionEnvelope: Decodable {
        let graphVersion: UInt32?
    }
}

actor InMemoryPersistence: MemoryPersistence {
    private var graph: MemoryGraph

    public init(graph: MemoryGraph = MemoryGraph()) {
        self.graph = graph
    }

    public func load() async throws -> MemoryGraph { graph }
    public func save(_ graph: MemoryGraph) async throws { self.graph = graph }
}
