//
//  ToolExecutionLogger.swift
//  ZenCODE
//

import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Durable local JSONL audit log for direct tool executions.
///
/// Each process launch writes a separate file. Calls produce a `started` record
/// and one terminal `completed` record correlated by sequence. Logging is
/// best-effort and never changes tool behavior.
public actor ToolExecutionLogger {
    public static let shared = ToolExecutionLogger()

    private static let processLaunchID = UUID().uuidString.lowercased()
    private static let directoryPermissions: Int16 = 0o700
    private static let filePermissions: Int16 = 0o600
    static let retentionInterval: TimeInterval = 10 * 24 * 60 * 60

    private let directoryURL: URL?
    private let now: () -> Date
    private let retentionCleanup: (URL, URL, Date) throws -> Void
    private var cachedLogURL: URL?
    private var hasAttemptedRetentionCleanup = false
    private var nextSequence: UInt64 = 0
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL
        self.now = Date.init
        self.retentionCleanup = Self.cleanupExpiredLogs
    }

    /// Testable initializer for controlling retention time and cleanup failures.
    init(
        directoryURL: URL? = nil,
        now: @escaping () -> Date
    ) {
        self.directoryURL = directoryURL
        self.now = now
        self.retentionCleanup = ToolExecutionLogger.cleanupExpiredLogs
    }

    init(
        directoryURL: URL? = nil,
        now: @escaping () -> Date,
        retentionCleanup: @escaping (URL, URL, Date) throws -> Void
    ) {
        self.directoryURL = directoryURL
        self.now = now
        self.retentionCleanup = retentionCleanup
    }

    public nonisolated static func defaultLogURL() -> URL {
        resolveLogURL()
    }

    public nonisolated static func resolveLogURL(directoryURL: URL? = nil) -> URL {
        let root = directoryURL ?? AppStorageDirectory.appSupportDirectoryURL()
        return root
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(
                "tool-executions-\(ProcessInfo.processInfo.processIdentifier)-\(processLaunchID).jsonl",
                isDirectory: false
            )
            .standardizedFileURL
    }

    @discardableResult
    public func recordStarted(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) -> UInt64? {
        appendRecord(
            event: "started",
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: workingDirectory,
            result: nil,
            output: nil,
            status: nil,
            elapsed: nil,
            correlatesTo: nil,
            failure: nil
        )
    }

    @discardableResult
    public func recordCompleted(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        result: DirectAgentToolResult,
        rawOutput: String? = nil,
        elapsed: Duration?,
        sequence: UInt64?
    ) -> UInt64? {
        appendRecord(
            event: "completed",
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: workingDirectory,
            result: result,
            output: rawOutput ?? result.output,
            status: String(describing: result.status),
            elapsed: elapsed,
            correlatesTo: sequence,
            failure: nil
        )
    }

    @discardableResult
    public func recordCompleted(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        elapsed: Duration?,
        sequence: UInt64?,
        status: String = "error",
        failure: String
    ) -> UInt64? {
        appendRecord(
            event: "completed",
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: workingDirectory,
            result: nil,
            output: nil,
            status: status,
            elapsed: elapsed,
            correlatesTo: sequence,
            failure: failure
        )
    }

    /// Creates and hardens the concrete per-process file used by `/tools logs`.
    public func ensureLogExists() throws -> URL {
        let url = logURL()
        try prepareLog(at: url)
        attemptRetentionCleanup(excluding: url)
        return url
    }

    private func logURL() -> URL {
        if let cachedLogURL { return cachedLogURL }
        let url = Self.resolveLogURL(directoryURL: directoryURL)
        cachedLogURL = url
        return url
    }

    private func appendRecord(
        event: String,
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        result: DirectAgentToolResult?,
        output: String?,
        status: String?,
        elapsed: Duration?,
        correlatesTo: UInt64?,
        failure: String?
    ) -> UInt64? {
        let sequence = nextSequence
        nextSequence &+= 1
        var record: [String: Any] = [
            "event": event,
            "timestamp": timestampFormatter.string(from: Date()),
            "sequence": sequence,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "processLaunchID": Self.processLaunchID,
            "toolID": ZenSecretRedactor.redact(toolCall.id),
            "tool": ZenSecretRedactor.redact(toolCall.name),
            "arguments": Self.redactedArguments(toolCall.argumentsJSON),
            "workingDirectory": ZenSecretRedactor.redact(workingDirectory.path)
        ]
        if let sessionID { record["sessionID"] = ZenSecretRedactor.redact(sessionID) }
        if let correlatesTo { record["correlatesTo"] = correlatesTo }
        if let status { record["status"] = status }
        if let elapsed { record["elapsedMilliseconds"] = Self.milliseconds(from: elapsed) }
        if let result {
            record["summary"] = Self.redactedText(result.summary)
        }
        if let output {
            record["output"] = Self.redactedText(output)
        }
        if let failure { record["failure"] = Self.redactedText(failure) }

        guard let data = try? JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        var line = data
        line.append(0x0A)
        return appendToLog(data: line) ? sequence : nil
    }

    /// Largest slice handed to ``ZenSecretRedactor`` in one call. The redactor
    /// replaces any input above its own byte ceiling wholesale, so long tool
    /// output is redacted line-aligned chunk by chunk: the audit record keeps the
    /// complete payload instead of collapsing into a single placeholder, and only
    /// a pathological single line beyond the ceiling is replaced on its own.
    static let redactionChunkBytes = 32 * 1_024

    static func redactedText(_ text: String) -> String {
        guard text.lengthOfBytes(using: .utf8) > redactionChunkBytes else {
            return ZenSecretRedactor.redact(text)
        }
        var chunks: [String] = []
        var current: [Substring] = []
        var currentBytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineBytes = line.utf8.count + 1
            if !current.isEmpty, currentBytes + lineBytes > redactionChunkBytes {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentBytes = 0
            }
            current.append(line)
            currentBytes += lineBytes
        }
        chunks.append(current.joined(separator: "\n"))
        return chunks.map(ZenSecretRedactor.redact).joined(separator: "\n")
    }

    /// Preserves JSON structure while replacing values under sensitive keys and
    /// redacting credential shapes in all remaining strings.
    private static func redactedArguments(_ json: String) -> Any {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return ZenSecretRedactor.redact(json)
        }
        return redactJSON(value, key: nil)
    }

    private static func redactJSON(_ value: Any, key: String?) -> Any {
        if let key, isSensitiveKey(key) { return ZenSecretRedactor.placeholder }
        if let dictionary = value as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (nestedKey, nestedValue) in dictionary {
                redacted[nestedKey] = redactJSON(nestedValue, key: nestedKey)
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map { redactJSON($0, key: nil) }
        }
        if let string = value as? String { return ZenSecretRedactor.redact(string) }
        return value
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return [
            "authorization", "cookie", "password", "passwd", "passphrase",
            "secret", "token", "apikey", "credential", "privatekey", "sessionid"
        ].contains { normalized.contains($0) }
    }

    private static func milliseconds(from elapsed: Duration) -> Int64 {
        let components = elapsed.components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }

    /// Creates the log directory and the per-process file, refusing any path
    /// component whose node type is not the expected one.
    private func prepareLog(at url: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = try openLogDescriptor(at: url)
        _ = close(descriptor)
        #else
        try prepareLogWithFileManager(at: url)
        #endif
    }

    /// Retention must never make tool logging unavailable. It is deliberately
    /// attempted only once per logger instance, after the current file has been
    /// prepared, and every cleanup failure is ignored.
    private func attemptRetentionCleanup(excluding currentLogURL: URL) {
        guard !hasAttemptedRetentionCleanup else { return }
        hasAttemptedRetentionCleanup = true
        try? retentionCleanup(currentLogURL.deletingLastPathComponent(), currentLogURL, now())
    }

    /// Removes only old, regular JSONL files bearing the name produced by this
    /// logger. `lstat` and `unlink` operate on directory entries themselves, so
    /// links are never followed; directories and all other node types are left
    /// untouched. This is intentionally non-recursive.
    static func cleanupExpiredLogs(in directory: URL, excluding currentLogURL: URL, now: Date) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let currentPath = currentLogURL.standardizedFileURL.path

        for entry in entries where isRecognizedLogFileName(entry.lastPathComponent) {
            guard entry.standardizedFileURL.path != currentPath else { continue }
            var info = stat()
            guard lstat(entry.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG else { continue }
            #if os(macOS)
            let seconds = info.st_mtimespec.tv_sec
            #else
            let seconds = info.st_mtim.tv_sec
            #endif
            let modified = Date(timeIntervalSince1970: TimeInterval(seconds))
            guard modified < cutoff else { continue }
            _ = unlink(entry.path)
        }
        #else
        // The descriptor-backed implementation above is used on supported
        // platforms. Keep the fallback conservative: no recursion and no
        // deletion through a symbolic-link resource value.
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let cutoff = now.addingTimeInterval(-retentionInterval)
        for entry in entries where isRecognizedLogFileName(entry.lastPathComponent) {
            guard entry.standardizedFileURL != currentLogURL.standardizedFileURL else { continue }
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try FileManager.default.removeItem(at: entry)
        }
        #endif
    }

    private static func isRecognizedLogFileName(_ name: String) -> Bool {
        guard name.hasPrefix("tool-executions-"), name.hasSuffix(".jsonl") else {
            return false
        }
        let prefixLength = "tool-executions-".count
        let suffixLength = ".jsonl".count
        let stem = String(name.dropFirst(prefixLength).dropLast(suffixLength))
        // The logger's format is `<numeric PID>-<UUID>`. Requiring the complete
        // UUID prevents unrelated files with a merely similar prefix from being
        // considered retention candidates.
        guard stem.count > 37 else { return false }
        let uuidStart = stem.index(stem.endIndex, offsetBy: -36)
        let separator = stem.index(before: uuidStart)
        guard stem[separator] == "-",
              Int32(stem[..<separator]) != nil else { return false }
        return UUID(uuidString: String(stem[uuidStart...])) != nil
    }

    #if canImport(Darwin) || canImport(Glibc)
    /// Opens the log with a single symlink-refusing handshake instead of a
    /// check-then-open sequence. `O_NOFOLLOW` makes the kernel fail rather than
    /// follow a final-component symlink (a dangling one included), `O_APPEND`
    /// keeps every record append-atomic against concurrent writers,
    /// `O_NONBLOCK` stops a FIFO planted at the path from blocking the open,
    /// and node type plus mode are validated on the descriptor itself with
    /// `fstat`/`fchmod`, so a path swapped after any check cannot widen access.
    private func openLogDescriptor(at url: URL) throws -> Int32 {
        try prepareDirectory(url.deletingLastPathComponent())
        let flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var descriptor: Int32 = -1
        while true {
            descriptor = open(url.path, flags, mode_t(Self.filePermissions))
            if descriptor >= 0 { break }
            let code = errno
            if code == EINTR { continue }
            switch code {
            // Linux and Darwin report ELOOP for O_NOFOLLOW; some BSDs use EMLINK.
            case ELOOP, EMLINK:
                throw ToolExecutionLogError.isSymbolicLink(url.path)
            // A directory, device, or reader-less FIFO occupying the path.
            case EISDIR, ENXIO, ENODEV, EOPNOTSUPP:
                throw ToolExecutionLogError.invalidFile(url.path)
            default:
                throw ToolExecutionLogError.cannotCreateFile(url.path)
            }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            _ = close(descriptor)
            throw ToolExecutionLogError.invalidFile(url.path)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            _ = close(descriptor)
            throw ToolExecutionLogError.invalidFile(url.path)
        }
        if info.st_mode & 0o7777 != mode_t(Self.filePermissions),
           fchmod(descriptor, mode_t(Self.filePermissions)) != 0 {
            _ = close(descriptor)
            throw ToolExecutionLogError.invalidFile(url.path)
        }
        return descriptor
    }

    private func prepareDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT != S_IFLNK else {
                throw ToolExecutionLogError.isSymbolicLink(directory.path)
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw ToolExecutionLogError.invalidDirectory(directory.path)
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
        }
        guard chmod(directory.path, mode_t(Self.directoryPermissions)) == 0 else {
            throw ToolExecutionLogError.invalidDirectory(directory.path)
        }
    }

    /// Writes the whole buffer, tolerating signal interruption and short writes.
    private func appendAll(descriptor: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
    }
    #else
    /// Portable fallback for platforms without POSIX descriptor primitives.
    private func prepareLogWithFileManager(at url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()

        if fileManager.fileExists(atPath: directory.path) {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ToolExecutionLogError.invalidDirectory(directory.path)
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
        }

        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw ToolExecutionLogError.isSymbolicLink(url.path)
                }
                throw ToolExecutionLogError.invalidFile(url.path)
            }
        } else {
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: Self.filePermissions]
            ) else {
                throw ToolExecutionLogError.cannotCreateFile(url.path)
            }
        }
    }
    #endif

    private func appendToLog(data: Data) -> Bool {
        let url = logURL()
        attemptRetentionCleanup(excluding: url)
        #if canImport(Darwin) || canImport(Glibc)
        do {
            let descriptor = try openLogDescriptor(at: url)
            defer { _ = close(descriptor) }
            return appendAll(descriptor: descriptor, data: data)
        } catch {
            return false
        }
        #else
        do {
            try prepareLogWithFileManager(at: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
        #endif
    }
}

public enum ToolExecutionLogError: LocalizedError, Equatable {
    case isSymbolicLink(String)
    case invalidDirectory(String)
    case invalidFile(String)
    case cannotCreateFile(String)

    public var errorDescription: String? {
        switch self {
        case let .isSymbolicLink(path):
            return "Refusing tool log path that is a symbolic link: \(path)"
        case let .invalidDirectory(path):
            return "Tool log directory is not a directory: \(path)"
        case let .invalidFile(path):
            return "Tool log path is not a regular file: \(path)"
        case let .cannotCreateFile(path):
            return "Cannot create tool log file: \(path)"
        }
    }
}

/// Strict parser for the logger's JSONL schema. It accepts only records that
/// ``ToolExecutionLogger`` actually emits: every known key is type-checked, the
/// timestamp must be ISO-8601, `started` records must carry no terminal fields,
/// and `completed` records must carry a status plus a correlation back to their
/// own `started` sequence. A malformed or incomplete object is reported by its
/// physical line number and never partially accepted.
public enum ToolExecutionLogParser {
    public struct Record: Sendable, Equatable {
        public let event: String
        public let timestamp: String
        public let sequence: UInt64
        public let pid: Int32
        public let processLaunchID: String
        public let sessionID: String?
        public let toolID: String
        public let tool: String
        /// Canonical JSON representation of the redacted arguments emitted by
        /// the logger. Keeping it makes a parsed completion verifiably belong
        /// to the exact invocation that opened the start record.
        public let arguments: String
        public let workingDirectory: String
        public let status: String?
        public let elapsedMilliseconds: Int64?
        public let summary: String?
        public let output: String?
        public let failure: String?
        public let correlatesTo: UInt64?
    }

    public struct ParseReport: Sendable, Equatable {
        public let records: [Record]
        public let malformedLines: [Int]
    }

    /// Exactly the keys the logger writes. An unknown key means the line was not
    /// produced by this schema version and is rejected instead of half-read.
    private static let knownKeys: Set<String> = [
        "event", "timestamp", "sequence", "pid", "processLaunchID", "toolID",
        "tool", "arguments", "workingDirectory", "sessionID", "correlatesTo",
        "status", "elapsedMilliseconds", "summary", "output", "failure"
    ]

    /// Status values written by the two completion paths above. Keep this set
    /// closed so a syntactically valid but foreign JSON object is not presented
    /// as one of our audit records.
    private static let knownStatuses: Set<String> = [
        "completed", "failed", "permissionDenied", "error"
    ]

    public static func parse(_ data: Data) -> ParseReport {
        guard let text = String(data: data, encoding: .utf8) else {
            return ParseReport(records: [], malformedLines: data.isEmpty ? [] : [1])
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> ParseReport {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var records: [Record] = []
        var malformedLines: [Int] = []
        var startsBySequence: [UInt64: Record] = [:]
        var completedStarts: Set<UInt64> = []
        var seenSequences: Set<UInt64> = []

        for (offset, line) in lines.enumerated() {
            guard let record = record(from: line),
                  seenSequences.insert(record.sequence).inserted else {
                malformedLines.append(offset + 1)
                continue
            }

            if record.event == "started" {
                startsBySequence[record.sequence] = record
                records.append(record)
                continue
            }

            guard let correlatesTo = record.correlatesTo,
                  let started = startsBySequence[correlatesTo],
                  !completedStarts.contains(correlatesTo),
                  hasSameExecutionIdentity(record, started) else {
                malformedLines.append(offset + 1)
                continue
            }
            completedStarts.insert(correlatesTo)
            records.append(record)
        }
        return ParseReport(records: records, malformedLines: malformedLines)
    }

    private static func hasSameExecutionIdentity(_ completed: Record, _ started: Record) -> Bool {
        completed.pid == started.pid
            && completed.processLaunchID == started.processLaunchID
            && completed.sessionID == started.sessionID
            && completed.toolID == started.toolID
            && completed.tool == started.tool
            && completed.arguments == started.arguments
            && completed.workingDirectory == started.workingDirectory
    }

    private static func record(from line: String) -> Record? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: knownKeys) else { return nil }

        guard let event = dictionary["event"] as? String,
              event == "started" || event == "completed",
              let timestamp = dictionary["timestamp"] as? String,
              isISO8601(timestamp),
              let sequence = unsignedInteger(dictionary["sequence"]),
              let pidValue = signedInteger(dictionary["pid"]),
              pidValue > 0, pidValue <= Int64(Int32.max),
              let launchID = nonEmptyString(dictionary["processLaunchID"]),
              let toolID = nonEmptyString(dictionary["toolID"]),
              let tool = nonEmptyString(dictionary["tool"]),
              let workingDirectory = nonEmptyString(dictionary["workingDirectory"]),
              let arguments = canonicalArguments(dictionary["arguments"]),
              optionalStringIsValid(dictionary["sessionID"]),
              optionalStringIsValid(dictionary["summary"]),
              optionalStringIsValid(dictionary["output"]),
              optionalStringIsValid(dictionary["failure"]) else { return nil }

        let status = dictionary["status"] as? String
        let correlatesTo = unsignedInteger(dictionary["correlatesTo"])
        let elapsed = signedInteger(dictionary["elapsedMilliseconds"])
        if dictionary["status"] != nil, status == nil || status?.isEmpty == true { return nil }
        if dictionary["correlatesTo"] != nil, correlatesTo == nil { return nil }
        if dictionary["elapsedMilliseconds"] != nil, elapsed == nil || elapsed! < 0 { return nil }

        switch event {
        case "started":
            // A start record is opened before the tool runs and therefore never
            // carries a terminal field.
            guard status == nil, correlatesTo == nil, elapsed == nil,
                  dictionary["summary"] == nil,
                  dictionary["output"] == nil,
                  dictionary["failure"] == nil else { return nil }
        default:
            // A terminal record always reports a status and correlates back to a
            // strictly earlier start sequence emitted by the same logger.
            guard let status, knownStatuses.contains(status),
                  let correlatesTo, correlatesTo < sequence else { return nil }
            // Either the tool produced a result summary or it failed outright,
            // and a failure never reports result payload.
            if dictionary["failure"] != nil {
                guard dictionary["summary"] == nil, dictionary["output"] == nil else { return nil }
            } else {
                guard dictionary["summary"] != nil, dictionary["output"] != nil else { return nil }
            }
        }

        return Record(
            event: event,
            timestamp: timestamp,
            sequence: sequence,
            pid: Int32(pidValue),
            processLaunchID: launchID,
            sessionID: dictionary["sessionID"] as? String,
            toolID: toolID,
            tool: tool,
            arguments: arguments,
            workingDirectory: workingDirectory,
            status: status,
            elapsedMilliseconds: elapsed,
            summary: dictionary["summary"] as? String,
            output: dictionary["output"] as? String,
            failure: dictionary["failure"] as? String,
            correlatesTo: correlatesTo
        )
    }

    /// `ISO8601DateFormatter` is not `Sendable`, so the parser builds its own
    /// formatters per call instead of sharing mutable global state.
    private static func isISO8601(_ text: String) -> Bool {
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ]
        return optionSets.contains { options in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            return formatter.date(from: text) != nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func optionalStringIsValid(_ value: Any?) -> Bool {
        value == nil || value is String
    }

    /// Arguments are emitted as the redacted JSON object, or as a redacted
    /// string when the original payload was not valid JSON.
    private static func canonicalArguments(_ value: Any?) -> String? {
        guard value is [String: Any] || value is [Any] || value is String,
              let data = try? JSONSerialization.data(
                  withJSONObject: value!,
                  options: [.sortedKeys, .fragmentsAllowed]
              ),
              let canonical = String(data: data, encoding: .utf8) else { return nil }
        return canonical
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e") else { return nil }
        return UInt64(text)
    }

    private static func signedInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e") else { return nil }
        return Int64(text)
    }
}
