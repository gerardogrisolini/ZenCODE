//
//  ToolExecutionLog.swift
//  ZenCODE
//

import Foundation
import ToolCore
#if canImport(OSLog)
import OSLog
#endif

/// Immutable identity attached to every tool execution log record.
///
/// A child backend receives its own context when it is created, so tools run by
/// delegated agents are attributed to the child rather than to the coordinator.
public struct ToolExecutionContext: Sendable, Equatable {
    public let agentID: String?
    public let agentName: String?
    public let modelID: String?
    public let isSubAgent: Bool

    public init(
        agentID: String? = nil,
        agentName: String? = nil,
        modelID: String? = nil,
        isSubAgent: Bool = false
    ) {
        self.agentID = agentID?.nilIfBlank
        self.agentName = agentName?.nilIfBlank
        self.modelID = modelID?.nilIfBlank
        self.isSubAgent = isSubAgent
    }

    func resolved(fallbackAgentID: String?) -> ToolExecutionContext {
        let fallbackAgentID = fallbackAgentID?.nilIfBlank
        let isSubAgent = isSubAgent || fallbackAgentID != nil
        return ToolExecutionContext(
            agentID: agentID ?? fallbackAgentID ?? (isSubAgent ? nil : "coordinator"),
            agentName: agentName ?? (isSubAgent ? nil : "coordinator"),
            modelID: modelID,
            isSubAgent: isSubAgent
        )
    }
}

struct ToolExecutionErrorMetadata: Codable, Sendable, Equatable {
    let type: String
    let domain: String
    let code: Int
    let message: String
    let debugDescription: String
    let failureReason: String?
    let recoverySuggestion: String?
    let underlyingErrors: [ToolExecutionErrorMetadata]
}

/// Codable payload written as the public message of a platform system-log entry.
/// Timestamps and process metadata are supplied by the system logger itself.
struct ToolExecutionLogEntry: Codable, Sendable, Equatable {
    let event: String
    let tool: String
    let toolCallID: String
    let arguments: JSONValue
    let agentID: String?
    let agentName: String?
    let model: String
    let isSubAgent: Bool
    let sessionID: String?
    let workingDirectory: String
    let durationMilliseconds: Int64?
    let status: String
    let summary: String
    let error: ToolExecutionErrorMetadata?
}

/// Emits tool execution records through the platform system logger.
///
/// On Apple platforms this uses Swift's ``Logger`` and Unified Logging directly;
/// no application-owned log file, retention policy, or parser is involved. The
/// open-source Swift toolchain does not ship `OSLog`, so Linux falls back to the
/// operating system's `logger(1)` bridge and therefore still targets syslog/the
/// systemd journal instead of an application file.
enum ToolExecutionLog {
    static let subsystem = "com.zencode.zen"
    static let category = "tool-execution"
    static let linuxTag = "zen"

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: subsystem, category: category)
    #endif

    static func record(
        context: ToolExecutionContext,
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        result: DirectAgentToolResult,
        duration: Duration?,
        error: Error? = nil
    ) {
        let entry = makeEntry(
            context: context,
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: workingDirectory,
            status: result.status,
            summary: result.summary,
            duration: duration,
            error: error
        )
        emit(entry)
    }

    static func makeEntry(
        context: ToolExecutionContext,
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        status: DirectAgentToolResult.Status,
        summary: String,
        duration: Duration?,
        error: Error?
    ) -> ToolExecutionLogEntry {
        ToolExecutionLogEntry(
            event: "tool_execution",
            tool: limitedRedactedText(toolCall.name, maximumCharacters: 512),
            toolCallID: limitedRedactedText(toolCall.id, maximumCharacters: 512),
            arguments: redactedArguments(toolCall.argumentsJSON),
            agentID: context.agentID.map {
                limitedRedactedText($0, maximumCharacters: 512)
            },
            agentName: context.agentName.map {
                limitedRedactedText($0, maximumCharacters: 512)
            },
            model: limitedRedactedText(
                context.modelID ?? "unknown",
                maximumCharacters: 1_024
            ),
            isSubAgent: context.isSubAgent,
            sessionID: sessionID?.nilIfBlank.map {
                limitedRedactedText($0, maximumCharacters: 512)
            },
            workingDirectory: limitedRedactedText(
                workingDirectory.standardizedFileURL.path,
                maximumCharacters: 4_096
            ),
            durationMilliseconds: duration.map(milliseconds(from:)),
            status: status.rawValue,
            summary: limitedRedactedText(summary, maximumCharacters: 2_048),
            error: error.map { errorMetadata(for: $0) }
        )
    }

    static func encodedMessage(for entry: ToolExecutionLogEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entry) else {
            return "tool_execution status=\(entry.status) tool=\(entry.tool)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func emit(_ entry: ToolExecutionLogEntry) {
        let message = encodedMessage(for: entry)
        #if canImport(OSLog)
        if entry.status == DirectAgentToolResult.Status.completed.rawValue {
            logger.notice("\(message, privacy: .public)")
        } else {
            logger.error("\(message, privacy: .public)")
        }
        #else
        emitThroughSystemLoggerCommand(
            message,
            isError: entry.status != DirectAgentToolResult.Status.completed.rawValue
        )
        #endif
    }

    private static func redactedArguments(_ json: String) -> JSONValue {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string(limitedRedactedText(json, maximumCharacters: 4_096))
        }
        let redactedValue = redactJSON(value, key: nil)
        guard let redactedData = try? JSONEncoder().encode(redactedValue),
              redactedData.count > 4_096 else {
            return redactedValue
        }
        return .string(
            limitedText(
                String(decoding: redactedData, as: UTF8.self),
                maximumCharacters: 4_096
            )
        )
    }

    private static func redactJSON(_ value: JSONValue, key: String?) -> JSONValue {
        if let key, isSensitiveKey(key) {
            return .string(ZenSecretRedactor.placeholder)
        }
        switch value {
        case let .object(dictionary):
            var redacted: [String: JSONValue] = [:]
            for (nestedKey, nestedValue) in dictionary {
                redacted[nestedKey] = redactJSON(nestedValue, key: nestedKey)
            }
            return .object(redacted)
        case let .array(array):
            return .array(array.map { redactJSON($0, key: nil) })
        case let .string(string):
            return .string(ZenSecretRedactor.redact(string))
        case .number, .bool, .null:
            return value
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return [
            "authorization", "cookie", "password", "passwd", "passphrase",
            "secret", "token", "apikey", "credential", "privatekey", "sessionid"
        ].contains { normalized.contains($0) }
    }

    private static func limitedRedactedText(
        _ text: String,
        maximumCharacters: Int
    ) -> String {
        limitedText(ZenSecretRedactor.redact(text), maximumCharacters: maximumCharacters)
    }

    private static func limitedText(
        _ text: String,
        maximumCharacters: Int
    ) -> String {
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "…"
    }

    private static func milliseconds(from duration: Duration) -> Int64 {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return max(0, milliseconds)
    }

    private static func errorMetadata(
        for error: Error,
        remainingDepth: Int = 4
    ) -> ToolExecutionErrorMetadata {
        let nsError = error as NSError
        let underlying: [Error]
        if remainingDepth > 0 {
            var candidates: [Error] = []
            if let single = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                candidates.append(single)
            }
            if let multiple = nsError.userInfo["NSMultipleUnderlyingErrors"] as? [Error] {
                candidates.append(contentsOf: multiple)
            }
            underlying = candidates
        } else {
            underlying = []
        }
        return ToolExecutionErrorMetadata(
            type: limitedRedactedText(
                String(reflecting: type(of: error)),
                maximumCharacters: 1_024
            ),
            domain: limitedRedactedText(nsError.domain, maximumCharacters: 1_024),
            code: nsError.code,
            message: limitedRedactedText(error.localizedDescription, maximumCharacters: 4_096),
            debugDescription: limitedRedactedText(
                String(reflecting: error),
                maximumCharacters: 4_096
            ),
            failureReason: nsError.localizedFailureReason.map {
                limitedRedactedText($0, maximumCharacters: 2_048)
            },
            recoverySuggestion: nsError.localizedRecoverySuggestion.map {
                limitedRedactedText($0, maximumCharacters: 2_048)
            },
            underlyingErrors: underlying.map {
                errorMetadata(for: $0, remainingDepth: remainingDepth - 1)
            }
        )
    }

    #if !canImport(OSLog)
    private static func emitThroughSystemLoggerCommand(
        _ message: String,
        isError: Bool
    ) {
        let candidates = ["/usr/bin/logger", "/bin/logger"]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-t", linuxTag,
            "-p", isError ? "user.err" : "user.notice",
            "--", message
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // System logging is observational and must never alter tool behavior.
        }
    }
    #endif
}
