//
//  ZenCODEHeadlessJSONLProtocol.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// The stable machine-readable protocol for one headless JSONL run.
///
/// Every record contains `schema_version`, `type`, and the opaque `run_id`.
/// The protocol deliberately exposes only lifecycle and tool identity: prompts,
/// arguments, thinking, diagnostics, tool output, summaries, and attachments
/// never cross this boundary.
public enum ZenCODEHeadlessJSONLProtocol {
    public static let schemaVersion = 1
    public static let version = schemaVersion

    /// The closed set of public error categories. Machine consumers match on
    /// these stable identifiers; the raw error is never exposed verbatim.
    public enum ErrorCategory: String, Sendable, CaseIterable {
        case configuration
        case provider
        case runtime
    }

    public struct PublicError: Error, Sendable, CustomStringConvertible {
        let category: ErrorCategory
        let publicMessage: String

        init(category: ErrorCategory, publicMessage: String) {
            self.category = category
            self.publicMessage = publicMessage
        }

        public var description: String {
            publicMessage
        }
    }

    /// The stable wording for each public error condition. Values derived from
    /// a failing error (descriptions, diagnostics, URLs, file paths) are never
    /// serialized: they are classified into one of these categories first.
    public enum PublicErrorMessages {
        public static let invalidArguments = "Invalid command-line arguments."
        public static let noPrompt = "No prompt provided. Pass text after -p/--prompt."
        public static let noResponse = "The backend produced no assistant text."
        public static let cancelled = "The headless run was cancelled."
        public static let turnFailed = "The headless run failed."
        public static let teardownFailed = "The session could not be finalized cleanly."
        public static let unknownError = "An unexpected error interrupted the run."

        /// The backend-facing equivalent of `invalidArguments`, preserving the
        /// legacy distinction between a syntactic and a semantic configuration
        /// failure at this boundary.
        public static let invalidConfiguration = "The ZenCODE configuration is invalid or incomplete."
    }

    public static func runStarted(runID: String) -> JSONValue {
        record(type: "run.started", runID: runID)
    }

    public static func toolStarted(
        runID: String,
        toolCall: DirectAgentToolCall
    ) -> JSONValue {
        record(
            type: "tool.started",
            runID: runID,
            values: [
                "id": .string(toolCall.id),
                "name": .string(toolCall.name)
            ]
        )
    }

    public static func toolCompleted(
        runID: String,
        toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> JSONValue {
        record(
            type: "tool.completed",
            runID: runID,
            values: [
                "id": .string(toolCall.id),
                "name": .string(toolCall.name),
                "status": .string(result.status.rawValue)
            ]
        )
    }

    public static func messageCompleted(
        runID: String,
        text: String
    ) -> JSONValue {
        record(
            type: "message.completed",
            runID: runID,
            values: ["text": .string(text)]
        )
    }

    public static func runCompleted(runID: String) -> JSONValue {
        record(
            type: "run.completed",
            runID: runID,
            values: ["status": .string("completed")]
        )
    }

    static func error(
        runID: String,
        category: ErrorCategory,
        message: String
    ) -> JSONValue {
        record(
            type: "error",
            runID: runID,
            values: [
                "category": .string(category.rawValue),
                "message": .string(message)
            ]
        )
    }

    /// Maps a failing error to the public, redacted error record. The error's
    /// own description is never serialized: only the stable public wording for
    /// its closed category is emitted.
    public static func error(runID: String, _ error: Error) -> JSONValue {
        let classified = classify(error)
        return Self.error(
            runID: runID,
            category: classified.category,
            message: classified.publicMessage
        )
    }

    /// The public, redacted error for a failing error. Use this instead of
    /// reading `localizedDescription` at the CLI boundary.
    public static func publicError(for error: Error) -> PublicError {
        if let error = error as? PublicError {
            return error
        }
        if let runnerError = error as? ZenCODEHeadlessRunnerError {
            switch runnerError {
            case .noPrompt:
                return PublicError(
                    category: .configuration,
                    publicMessage: PublicErrorMessages.noPrompt
                )
            case .noResponse:
                return PublicError(
                    category: .runtime,
                    publicMessage: PublicErrorMessages.noResponse
                )
            }
        }
        if let error = error as? AgentConfigurationError {
            return PublicError(
                category: .configuration,
                publicMessage: Self.publicMessage(forConfigurationError: error)
            )
        }
        if error is AgentProfileStoreError || error is AgentSettingsManifestStoreError {
            return PublicError(
                category: .configuration,
                publicMessage: PublicErrorMessages.invalidConfiguration
            )
        }
        if error is CancellationError {
            return PublicError(
                category: .runtime,
                publicMessage: PublicErrorMessages.cancelled
            )
        }
        if error is ZenCODEHeadlessTeardownError {
            return PublicError(
                category: .runtime,
                publicMessage: PublicErrorMessages.teardownFailed
            )
        }
        if error is URLError || error is RemoteTransportError {
            return PublicError(
                category: .provider,
                publicMessage: PublicErrorMessages.unknownError
            )
        }
        return PublicError(
            category: .runtime,
            publicMessage: PublicErrorMessages.unknownError
        )
    }

    private static func publicMessage(forConfigurationError error: AgentConfigurationError) -> String {
        switch error {
        case let .missingValue(option) where option == "--prompt" || option == "-p":
            return PublicErrorMessages.noPrompt
        case .missingValue:
            return PublicErrorMessages.invalidArguments
        case .conflictingOptions, .invalidValue, .unknownArgument:
            return PublicErrorMessages.invalidArguments
        case .unknownAgent:
            return PublicErrorMessages.invalidConfiguration
        }
    }

    private static func classify(_ error: Error) -> PublicError {
        publicError(for: error)
    }

    /// Compatibility helper for callers that need to serialize an error
    /// before a runner/writer exists. It creates a fresh run identifier only
    /// when one was not supplied by the caller.
    public static func error(_ error: Error, runID: String = UUID().uuidString) -> JSONValue {
        self.error(runID: runID, error)
    }

    /// Writes one framed record (payload and terminating LF) as a single
    /// serialized write. It is used at CLI boundaries before a live writer
    /// exists; stdout receives a complete JSON Lines record, never a payload
    /// and framing byte in separate writes.
    public static func writeFramedRecord(
        _ record: JSONValue,
        to output: FileHandle = AgentOutput.standardOutput
    ) {
        guard var data = try? encoded(record) else {
            return
        }
        data.append(0x0A)
        output.write(data)
    }

    /// Convenience overload that redacts and frames a failing error as the
    /// terminal record of a run without a live writer.
    public static func writeFramedError(
        _ error: Error,
        runID: String = UUID().uuidString,
        to output: FileHandle = AgentOutput.standardOutput
    ) {
        writeFramedRecord(Self.error(runID: runID, error), to: output)
    }

    /// The closed category set as raw strings, for validation and tests.
    public static let errorCategories = ErrorCategory.allCases.map(\.rawValue)

    public static func category(for error: Error) -> String {
        publicError(for: error).category.rawValue
    }

    public static func message(for error: Error) -> String {
        publicError(for: error).publicMessage
    }

    /// Converts a protocol object to compact UTF-8. The writer adds the LF
    /// framing byte after this payload.
    public static func encoded(_ value: JSONValue) throws -> Data {
        try value.jsonData(outputFormatting: [.withoutEscapingSlashes])
    }

    /// Maps only protocol-approved runtime events. All other internal events
    /// intentionally return `nil` and are ignored by the writer.
    public static func record(
        for event: DirectAgentEvent,
        runID: String
    ) -> JSONValue? {
        switch event {
        case let .toolCallStarted(toolCall):
            return toolStarted(runID: runID, toolCall: toolCall)
        case let .toolCallCompleted(toolCall, result):
            return toolCompleted(runID: runID, toolCall: toolCall, result: result)
        case .status, .diagnostic, .thought, .modelLoaded, .metrics,
             .contextWindow, .subscriptionUsage, .content, .sessionSnapshot:
            return nil
        case .turnEnded:
            // A successful turn is emitted by `runCompleted(runID:)` only after
            // the runner has supplied and validated its non-empty final text.
            // Failed/cancelled turn outcomes are converted by the writer to a
            // terminal error record.
            return nil
        }
    }

    private static func record(
        type: String,
        runID: String,
        values: [String: JSONValue] = [:]
    ) -> JSONValue {
        var object = values
        object["schema_version"] = .number(Double(schemaVersion))
        object["type"] = .string(type)
        object["run_id"] = .string(runID)
        return .object(object)
    }
}

public typealias HeadlessJSONLProtocol = ZenCODEHeadlessJSONLProtocol

/// Actor-isolated, ordered writer for headless JSON Lines records.
///
/// A sink receives one complete compact JSON record including its trailing LF.
/// Consequently every sink invocation corresponds exactly to the single write
/// performed in production and tests can assert framing without a special path.
public actor ZenCODEHeadlessJSONLWriter {
    public typealias Sink = @Sendable (Data) -> Void

    public let runID: String
    private let sink: Sink
    private var isClosed = false
    private var startedRecordWritten = false
    private var terminalRecordWritten = false
    private var pendingTurnFailure: (
        category: ZenCODEHeadlessJSONLProtocol.ErrorCategory,
        message: String
    )?

    public init(runID: String = UUID().uuidString, sink: Sink? = nil) {
        self.runID = runID
        self.sink = sink ?? { data in
            AgentOutput.standardOutput.write(data)
        }
    }

    public func start() {
        guard !isClosed, !terminalRecordWritten, !startedRecordWritten else { return }
        startedRecordWritten = true
        write(record: ZenCODEHeadlessJSONLProtocol.runStarted(runID: runID))
    }

    public func write(event: DirectAgentEvent) {
        guard !isClosed, !terminalRecordWritten else { return }
        if let record = ZenCODEHeadlessJSONLProtocol.record(for: event, runID: runID) {
            write(record: record)
            return
        }
        guard case let .turnEnded(outcome) = event else {
            // Keep status, content, thinking, diagnostics, metrics, context,
            // usage, model-load, snapshots and all future internal events off
            // the public JSONL wire until explicitly approved by the protocol
            // mapper.
            return
        }

        // A failed/cancelled `sendPrompt` is followed by a thrown underlying
        // error. Defer the terminal record so the catch path can preserve its
        // provider/runtime category.
        switch outcome.status {
        case .completed:
            // The terminal marker is emitted by `write(result:)` only after the
            // runner has supplied and validated its non-empty final text.
            break
        case .cancelled:
            pendingTurnFailure = (
                category: .runtime,
                message: ZenCODEHeadlessJSONLProtocol.PublicErrorMessages.cancelled
            )
        case .failed:
            pendingTurnFailure = (
                category: .runtime,
                message: ZenCODEHeadlessJSONLProtocol.PublicErrorMessages.turnFailed
            )
        }
    }

    public func write(_ event: DirectAgentEvent) {
        write(event: event)
    }

    /// Emits the final text and successful completion marker. The runner calls
    /// this only after checking that the response text is not empty.
    public func write(result response: DirectAgentResponse) {
        guard !isClosed, !terminalRecordWritten, pendingTurnFailure == nil else { return }
        guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        write(record: ZenCODEHeadlessJSONLProtocol.messageCompleted(
            runID: runID,
            text: response.text
        ))
        write(record: ZenCODEHeadlessJSONLProtocol.runCompleted(runID: runID))
        terminalRecordWritten = true
    }

    public func write(response: DirectAgentResponse) {
        write(result: response)
    }

    public func write(error: Error) {
        guard !isClosed, !terminalRecordWritten else { return }
        let classified = ZenCODEHeadlessJSONLProtocol.publicError(for: error)
        pendingTurnFailure = nil
        writeTerminalError(
            category: classified.category,
            message: classified.publicMessage
        )
    }

    public func close() {
        if !terminalRecordWritten, let pendingTurnFailure {
            writeTerminalError(
                category: pendingTurnFailure.category,
                message: pendingTurnFailure.message
            )
            self.pendingTurnFailure = nil
        }
        isClosed = true
    }

    private func writeTerminalError(
        category: ZenCODEHeadlessJSONLProtocol.ErrorCategory,
        message: String
    ) {
        guard !isClosed, !terminalRecordWritten else { return }
        write(record: ZenCODEHeadlessJSONLProtocol.error(
            runID: runID,
            category: category,
            message: message
        ))
        terminalRecordWritten = true
    }

    private func write(record: JSONValue) {
        guard !isClosed,
              var data = try? ZenCODEHeadlessJSONLProtocol.encoded(record) else {
            return
        }
        data.append(0x0A)
        sink(data)
    }
}

public typealias HeadlessJSONLWriter = ZenCODEHeadlessJSONLWriter
