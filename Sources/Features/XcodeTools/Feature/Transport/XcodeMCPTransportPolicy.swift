//
//  XcodeMCPTransportPolicy.swift
//  ZenCODE
//

import Foundation
import FeatureMCPBridgeKit

/// Supplies the mcpbridge-specific exception handling without making the MCP
/// transport itself aware of Xcode, its consent UI, or Unified Logging.
public nonisolated enum XcodeMCPTransportPolicy {
    public static func make() -> LocalMCPTransportPolicy {
        LocalMCPTransportPolicy(
            handshake: .optimisticInitialized,
            diagnosticMonitor: { processID in
                #if os(macOS)
                LocalMCPDiagnosticMonitorConfiguration(
                    executablePath: "/usr/bin/log",
                    arguments: [
                        "stream",
                        "--style", "compact",
                        "--predicate", "processID == \(processID)",
                        "--info",
                        "--debug"
                    ]
                )
                #else
                _ = processID
                nil
                #endif
            },
            errorClassifier: authorizationError(for:)
        )
    }

    private static func authorizationError(
        for event: LocalMCPTransportEvent
    ) -> MCPClientError? {
        switch event.kind {
        case .stderr:
            return messageLooksLikeConsentDenied(event.message)
                ? XcodeMCPServerConfiguration.authorizationError()
                : nil

        case .stdout:
            return bridgeOutputLooksLikeConsentDenied(event.message)
                ? XcodeMCPServerConfiguration.authorizationError()
                : nil

        case .invalidMessage:
            return hasPendingToolsList(event)
                || bridgeOutputLooksLikeConsentDenied(event.message)
                ? XcodeMCPServerConfiguration.authorizationError()
                : nil

        case .serverError:
            guard event.requestMethod == "tools/list"
                || ["initialize", "tools/call"].contains(event.requestMethod) else {
                return nil
            }
            if event.requestMethod == "tools/list"
                || messageLooksLikeConsentDenied(event.message)
                || bridgeErrorLooksLikeConsentDenied(
                    message: event.message,
                    code: event.errorCode
                ) {
                return XcodeMCPServerConfiguration.authorizationError()
            }
            return nil

        case .missingResult:
            return event.requestMethod == "tools/list"
                ? XcodeMCPServerConfiguration.authorizationError()
                : nil

        case .unroutedMessage:
            return hasPendingToolsList(event)
                ? XcodeMCPServerConfiguration.authorizationError()
                : nil

        case .stdoutClosed, .processExited:
            if messageLooksLikeConsentDenied(event.message) || !event.hasStderrOutput {
                return XcodeMCPServerConfiguration.authorizationError()
            }
            return nil

        case .diagnostic:
            guard hasPendingToolsList(event) else {
                return nil
            }
            let lowered = event.message.lowercased()
            return lowered.contains("listtools request failed")
                || lowered.contains("bridgeerror code=1")
                || (lowered.contains("bridgeerror") && lowered.contains("code=1"))
                ? XcodeMCPServerConfiguration.authorizationError()
                : nil
        }
    }

    private static func hasPendingToolsList(_ event: LocalMCPTransportEvent) -> Bool {
        event.pendingRequestMethods.contains("tools/list")
    }

    private static func messageLooksLikeConsentDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("permission")
            || lowered.contains("authorize")
            || lowered.contains("authorization")
            || lowered.contains("authorisation")
            || lowered.contains("consent")
            || lowered.contains("denied")
            || lowered.contains("not allowed")
            || lowered.contains("not permitted")
            || lowered.contains("rejected")
            || lowered.contains("declined")
            || lowered.contains("cancelled")
            || lowered.contains("canceled")
    }

    private static func bridgeOutputLooksLikeConsentDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("bridgeerror code=1")
            || lowered.contains("bridgeerror code 1")
            || lowered.contains("bridgeerror 1")
            || (lowered.contains("ideintelligencemessaging")
                && lowered.contains("bridgeerror")
                && lowered.contains("code=1"))
    }

    private static func bridgeErrorLooksLikeConsentDenied(
        message: String,
        code: Int?
    ) -> Bool {
        let lowered = message.lowercased()
        return code == 1
            || lowered.contains("bridgeerror code=1")
            || lowered.contains("bridgeerror error 1")
            || lowered.contains("bridgeerror code 1")
            || lowered.contains("bridgeerror 1")
    }
}
