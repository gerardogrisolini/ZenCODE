//
//  FeaturePersistentProcessProtocol.swift
//  ZenCODE
//

import Foundation

/// A request sent over the private, session-scoped JSON-lines transport used by
/// opt-in feature executables. Invoke requests carry the same argument bytes a
/// one-shot `--invoke` process receives on stdin; response framing remains
/// separate so the public feature command protocol stays unchanged.
public struct FeaturePersistentRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case listTools
        case invoke
        case shutdown
    }

    public let id: UUID
    public let operation: Operation
    public let toolName: String?
    public let workingDirectoryPath: String?
    public let inputData: Data?

    public init(
        id: UUID = UUID(),
        operation: Operation,
        toolName: String? = nil,
        workingDirectoryPath: String? = nil,
        inputData: Data? = nil
    ) {
        self.id = id
        self.operation = operation
        self.toolName = toolName
        self.workingDirectoryPath = workingDirectoryPath
        self.inputData = inputData
    }
}

/// One JSON-lines response from an opt-in persistent feature process.
///
/// `responseData` is the exact JSON response payload of the equivalent
/// one-shot feature command, including its newline when present. Keeping it as
/// opaque bytes isolates this private framing from every existing public
/// feature response format.
public struct FeaturePersistentResponse: Codable, Sendable {
    public let id: UUID
    public let responseData: Data?
    public let error: String?

    public init(id: UUID, responseData: Data?, error: String? = nil) {
        self.id = id
        self.responseData = responseData
        self.error = error
    }
}

/// Error emitted by the generic persistent process client. Stderr is retained
/// as a bounded diagnostic tail so an unexpected EOF or child crash remains
/// actionable without allowing an untrusted process to consume unbounded RAM.
public struct FeaturePersistentProcessError: LocalizedError, Sendable {
    public enum Kind: String, Sendable {
        case unavailable
        case closed
        case timedOut
        case malformedResponse
        case remote
    }

    public let kind: Kind
    public let message: String
    public let stderr: String

    public init(kind: Kind, message: String, stderr: String = "") {
        self.kind = kind
        self.message = message
        self.stderr = stderr
    }

    public var errorDescription: String? {
        guard !stderr.isEmpty else {
            return message
        }
        return "\(message)\nstderr:\n\(stderr)"
    }
}
