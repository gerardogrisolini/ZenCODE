//
//  MCPClient+StdioEvents.swift
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
/// Connection-scoped stdout/stderr/diagnostic events delivered by the shared
/// stream pump. Everything here runs on the actor and only decides whether an
/// event still belongs to the active generation, plus how bounded diagnostic
/// output is retained.
extension MCPClient {
    static let maxDiagnosticBytes = 65_536

    // MARK: - stdout

    func handleStdoutChunk(_ chunk: Data) {
        append(chunk)
    }

    func handleStdoutChunk(_ chunk: Data, connectionID: UUID) {
        guard activeConnectionID == connectionID else {
            return
        }
        handleStdoutChunk(chunk)
    }

    func handleStdoutReadFailure(_ error: Error) {
        guard terminatingConnectionID == nil else {
            return
        }
        resumeAllPending(with: error)
    }

    func handleStdoutReadFailure(_ error: Error, connectionID: UUID) {
        guard activeConnectionID == connectionID else {
            return
        }
        handleStdoutReadFailure(error)
    }

    func handleStdoutClosed() {
        guard terminatingConnectionID == nil else {
            return
        }
        if let terminalBridgeError {
            resumeAllPending(with: terminalBridgeError)
            return
        }

        let stderrMessage = currentStderrMessage()
        if let error = classifiedPolicyError(
            kind: .stdoutClosed,
            message: stderrMessage,
            hasStderrOutput: !stderrMessage.isEmpty
        ) {
            applyClassifiedPolicyError(error)
            resumeAllPending(with: error)
            return
        }

        resumeAllPending(with: MCPClientError.connectionClosed)
    }

    func handleStdoutClosed(connectionID: UUID) {
        guard activeConnectionID == connectionID,
              terminatingConnectionID != connectionID else {
            return
        }

        // EOF can arrive before Process invokes its termination handler. Let
        // that handler own the final drain and pending-response failure so a
        // reply written immediately before exit cannot lose to
        // `.connectionClosed`.
        guard let process else {
            handleStdoutClosed()
            return
        }

        let wasRunning = process.isRunning
        terminatingConnectionID = connectionID
        if wasRunning {
            terminalBridgeError = terminalBridgeError ?? .connectionClosed
            FeatureProcessTreeSupervisor.send(
                SIGKILL,
                to: process,
                processGroupLeader: FeatureProcessTreeSupervisor.isProcessGroupLeader(process)
            )
        }
    }

    // MARK: - stderr

    func handleStderrChunk(_ chunk: Data) {
        appendDiagnostic(chunk, to: &stderrBuffer)

        guard terminalBridgeError == nil else {
            return
        }

        let stderrMessage = currentStderrMessage()
        guard let detectedError = classifiedPolicyError(
            kind: .stderr,
            message: stderrMessage,
            hasStderrOutput: !stderrMessage.isEmpty
        ) else {
            return
        }

        applyClassifiedPolicyError(detectedError)
        resumeAllPending(with: detectedError)
    }

    func handleStderrChunk(_ chunk: Data, connectionID: UUID) {
        guard activeConnectionID == connectionID else {
            return
        }
        handleStderrChunk(chunk)
    }

    func handleStderrReadFailure(_ error: Error) {
        appendDiagnostic(Data(error.localizedDescription.utf8), to: &stderrBuffer)
    }

    func handleStderrReadFailure(_ error: Error, connectionID: UUID) {
        guard activeConnectionID == connectionID else {
            return
        }
        handleStderrReadFailure(error)
    }

    // MARK: - Diagnostic monitor

    func handleDiagnosticLine(_ line: String) {
        guard let policyError = classifiedPolicyError(
            kind: .diagnostic,
            message: line
        ) else {
            return
        }

        applyClassifiedPolicyError(policyError)
        resumeAllPending(with: policyError)
    }

    func handleDiagnosticLine(_ line: String, connectionID: UUID) {
        guard activeConnectionID == connectionID,
              diagnosticMonitorConnectionID == connectionID,
              terminatingConnectionID != connectionID else {
            return
        }
        handleDiagnosticLine(line)
    }

    // MARK: - Reader stop predicates

    func shouldStopReaderAfterProcessTermination(connectionID: UUID) -> Bool {
        activeConnectionID != connectionID || terminatingConnectionID == connectionID
    }

    func shouldStopDiagnosticMonitor(connectionID: UUID) -> Bool {
        activeConnectionID != connectionID
            || diagnosticMonitorConnectionID != connectionID
            || terminatingConnectionID == connectionID
    }

    // MARK: - Bounded diagnostic retention

    func currentStderrMessage() -> String {
        String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func appendDiagnostic(_ chunk: Data, to buffer: inout Data) {
        guard chunk.count < Self.maxDiagnosticBytes else {
            buffer = Data(chunk.suffix(Self.maxDiagnosticBytes))
            return
        }
        let overflow = buffer.count.addingReportingOverflow(chunk.count)
        if overflow.overflow || overflow.partialValue > Self.maxDiagnosticBytes {
            let bytesToRemove = min(
                buffer.count,
                overflow.overflow
                    ? buffer.count
                    : overflow.partialValue - Self.maxDiagnosticBytes
            )
            buffer.removeFirst(bytesToRemove)
        }
        buffer.append(chunk)
    }
}
#endif
