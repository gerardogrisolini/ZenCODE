//
//  MCPClient+TransportPolicy.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#endif
import Foundation
import FeatureKit

#if os(macOS)
/// Classification of local transport events through the injected policy, and the
/// terminal actions a classified error implies. Classification stays generic:
/// feature-specific meaning lives entirely in `LocalMCPTransportPolicy`.
extension MCPClient {
    func classifiedPolicyError(
        kind: LocalMCPTransportEvent.Kind,
        message: String = "",
        requestMethod: String? = nil,
        errorCode: Int? = nil,
        hasStderrOutput: Bool = false,
        terminationStatus: Int32? = nil
    ) -> MCPClientError? {
        localTransportPolicy.errorClassifier(
            LocalMCPTransportEvent(
                kind: kind,
                message: message,
                requestMethod: requestMethod,
                errorCode: errorCode,
                pendingRequestMethods: pendingRequestMethods.values.sorted(),
                hasStderrOutput: hasStderrOutput,
                terminationStatus: terminationStatus
            )
        )
    }

    /// Wraps classified `.serverError` policy logic in one place so the bridge
    /// and its tests share an identical classification path. Production routing
    /// inlines `classifiedPolicyError` with this kind; direct calls serve
    /// focused policy classification tests.
    func serverError(
        _ error: MCPErrorResponse,
        requestMethod: String?
    ) -> MCPClientError {
        classifiedPolicyError(
            kind: .serverError,
            message: error.message,
            requestMethod: requestMethod,
            errorCode: error.code
        ) ?? .serverError(code: error.code, message: error.message)
    }

    func exitError(for process: Process) -> MCPClientError {
        let stderrMessage = currentStderrMessage()
        if let policyError = classifiedPolicyError(
            kind: .processExited,
            message: stderrMessage,
            hasStderrOutput: !stderrMessage.isEmpty,
            terminationStatus: process.terminationStatus
        ) {
            return policyError
        }

        let message = stderrMessage.isEmpty
            ? "The local MCP server exited without diagnostics."
            : stderrMessage

        log("Bridge exited with status \(process.terminationStatus). stderr: \(message)")
        return .serverExited(status: process.terminationStatus, message: message)
    }

    func handleUnroutedPolicyMessage(_ message: MCPIncomingMessage) -> Bool {
        let text: String
        let errorCode: Int?
        if let error = message.error {
            text = error.message
            errorCode = error.code
        } else {
            text = "Unrouted MCP response"
            errorCode = nil
        }

        guard let policyError = classifiedPolicyError(
            kind: .unroutedMessage,
            message: text,
            errorCode: errorCode
        ) else {
            return false
        }

        applyClassifiedPolicyError(policyError)
        resumeAllPending(with: policyError)
        return true
    }

    func applyClassifiedPolicyError(_ error: MCPClientError) {
        terminalBridgeError = error
        guard localTransportPolicy.terminateProcessOnClassifiedError else {
            return
        }
        terminateLocalProcessAfterPolicyError(error)
    }

    func terminateLocalProcessAfterPolicyError(_ error: MCPClientError) {
        terminalBridgeError = error
        if let activeConnectionID {
            terminatingConnectionID = activeConnectionID
        }
        // Detach the writer's descriptor BEFORE closing it. This path closes stdin
        // synchronously while the writer's consumer may still hold a claimed
        // frame, so without the gate a job could write onto a closed — or already
        // recycled — descriptor. Invalidation is synchronous and needs no join,
        // so it is safe here; the full bounded teardown runs in
        // `handleProcessTermination` once the SIGKILLed process is reaped.
        writer?.invalidateDescriptor()
        inputHandle?.closeFile()
        inputHandle = nil

        guard let process else {
            return
        }

        if process.isRunning {
            importantLog("Terminating local MCP process after a classified transport error.")
            FeatureProcessTreeSupervisor.send(
                SIGKILL,
                to: process,
                processGroupLeader: FeatureProcessTreeSupervisor.isProcessGroupLeader(process)
            )
        }
    }
}
#endif
