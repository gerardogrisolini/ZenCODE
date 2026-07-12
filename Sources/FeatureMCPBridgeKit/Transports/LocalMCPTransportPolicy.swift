//
//  LocalMCPTransportPolicy.swift
//  ZenCODE
//

import Foundation

/// Describes optional behavior for a local stdio MCP transport without making
/// that behavior part of `MCPServerConfiguration` identity.
public struct LocalMCPTransportPolicy: Sendable {
    public enum Handshake: Sendable, Equatable {
        /// Wait for the initialize response before sending initialized.
        case standard
        /// Send initialized as soon as initialize has been written.
        case optimisticInitialized
    }

    public let handshake: Handshake
    public let diagnosticMonitor: @Sendable (Int32) -> LocalMCPDiagnosticMonitorConfiguration?
    public let errorClassifier: @Sendable (LocalMCPTransportEvent) -> MCPClientError?
    public let terminateProcessOnClassifiedError: Bool

    public init(
        handshake: Handshake = .standard,
        diagnosticMonitor: @escaping @Sendable (Int32) -> LocalMCPDiagnosticMonitorConfiguration? = { _ in nil },
        errorClassifier: @escaping @Sendable (LocalMCPTransportEvent) -> MCPClientError? = { _ in nil },
        terminateProcessOnClassifiedError: Bool = true
    ) {
        self.handshake = handshake
        self.diagnosticMonitor = diagnosticMonitor
        self.errorClassifier = errorClassifier
        self.terminateProcessOnClassifiedError = terminateProcessOnClassifiedError
    }

    public static let standard = LocalMCPTransportPolicy()
}

public struct LocalMCPDiagnosticMonitorConfiguration: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let combinesStandardError: Bool

    public init(
        executablePath: String,
        arguments: [String],
        combinesStandardError: Bool = true
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.combinesStandardError = combinesStandardError
    }
}

public struct LocalMCPTransportEvent: Sendable {
    public enum Kind: Sendable {
        case stdoutClosed
        case stderr
        case stdout
        case invalidMessage
        case serverError
        case missingResult
        case unroutedMessage
        case processExited
        case diagnostic
    }

    public let kind: Kind
    public let message: String
    public let requestMethod: String?
    public let errorCode: Int?
    public let pendingRequestMethods: [String]
    public let hasStderrOutput: Bool
    public let terminationStatus: Int32?

    public init(
        kind: Kind,
        message: String = "",
        requestMethod: String? = nil,
        errorCode: Int? = nil,
        pendingRequestMethods: [String] = [],
        hasStderrOutput: Bool = false,
        terminationStatus: Int32? = nil
    ) {
        self.kind = kind
        self.message = message
        self.requestMethod = requestMethod
        self.errorCode = errorCode
        self.pendingRequestMethods = pendingRequestMethods
        self.hasStderrOutput = hasStderrOutput
        self.terminationStatus = terminationStatus
    }
}
