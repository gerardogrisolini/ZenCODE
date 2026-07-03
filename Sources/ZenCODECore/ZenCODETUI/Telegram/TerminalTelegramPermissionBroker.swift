//
//  TerminalTelegramPermissionBroker.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 11/06/26.
//

import Foundation

enum TerminalTelegramPermissionDecision: Sendable, Equatable {
    case allowOnce
    case allowAlways
    case deny
}

struct TerminalTelegramPermissionCommand: Sendable, Equatable {
    let decision: TerminalTelegramPermissionDecision
    let requestID: String?
}

enum TerminalTelegramPermissionMessageResult: Sendable, Equatable {
    case notHandled
    case handled(reply: String?)

    var isHandled: Bool {
        if case .handled = self {
            return true
        }
        return false
    }
}

private enum TerminalTelegramPermissionResolution: Sendable, Equatable {
    case decision(TerminalTelegramPermissionDecision)
    case timedOut
    case cancelled
}

actor TerminalTelegramPermissionBroker {
    static let defaultTimeoutNanoseconds: UInt64 = 600_000_000_000

    private struct PendingRequest {
        let id: String
        let chatID: Int64
        let request: AgentToolAuthorizationRequest
        let continuation: CheckedContinuation<TerminalTelegramPermissionResolution, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private var nextRequestCounter = 0
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingRequestIDsByChat: [Int64: [String]] = [:]

    func authorize(
        _ request: AgentToolAuthorizationRequest,
        chatID: Int64,
        timeoutNanoseconds: UInt64 = TerminalTelegramPermissionBroker.defaultTimeoutNanoseconds,
        sendMessage: @escaping @Sendable (String) async -> Void
    ) async -> Bool {
        guard request.toolName == "local.exec" else {
            return true
        }
        if LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(request.command) {
            return true
        }

        let requestID = newRequestID()
        let resolution = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    let timeoutTask = makeTimeoutTask(
                        requestID: requestID,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                    pendingRequests[requestID] = PendingRequest(
                        id: requestID,
                        chatID: chatID,
                        request: request,
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
                    pendingRequestIDsByChat[chatID, default: []].append(requestID)

                    let message = Self.permissionRequestMessage(
                        requestID: requestID,
                        request: request
                    )
                    Task {
                        await sendMessage(message)
                    }
                }
            },
            onCancel: {
                Task {
                    await self.resolveRequest(id: requestID, resolution: .cancelled)
                }
            }
        )

        switch resolution {
        case .decision(.allowOnce):
            return true
        case .decision(.allowAlways):
            LocalExecPermissionAuthorizer.persistAllowedCommand(request.command)
            return true
        case .decision(.deny), .cancelled:
            return false
        case .timedOut:
            await sendMessage(Self.permissionTimedOutMessage(requestID: requestID))
            return false
        }
    }

    func handleMessage(
        _ text: String,
        chatID: Int64
    ) -> TerminalTelegramPermissionMessageResult {
                let pendingIDs = pendingRequestIDs(for: chatID)
        guard !pendingIDs.isEmpty else {
            guard Self.permissionCommand(from: text) != nil else {
                return .notHandled
            }
            return .handled(reply: Self.noPendingPermissionRequestMessage())
        }

        guard let command = Self.permissionCommand(from: text) else {
            return .handled(reply: Self.pendingPermissionReminder(requestIDs: pendingIDs))
        }

        let requestID: String
        if let explicitRequestID = command.requestID {
            requestID = explicitRequestID
            guard pendingIDs.contains(requestID) else {
                return .handled(
                    reply: Self.unknownPermissionRequestMessage(
                        requestID: requestID,
                        pendingRequestIDs: pendingIDs
                    )
                )
            }
        } else {
            guard pendingIDs.count == 1, let onlyRequestID = pendingIDs.first else {
                return .handled(reply: Self.ambiguousPermissionRequestMessage(requestIDs: pendingIDs))
            }
            requestID = onlyRequestID
        }

        guard resolveRequest(id: requestID, resolution: .decision(command.decision)) else {
            return .handled(
                reply: Self.unknownPermissionRequestMessage(
                    requestID: requestID,
                    pendingRequestIDs: pendingIDs
                )
            )
        }

        return .handled(
            reply: Self.permissionResolvedMessage(
                requestID: requestID,
                decision: command.decision
            )
        )
    }

    static func permissionCommand(from text: String) -> TerminalTelegramPermissionCommand? {
        let parts = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        guard let rawCommand = parts.first else {
            return nil
        }

        guard String(rawCommand).hasPrefix("/") else {
            return nil
        }
        let command = normalizedCommand(String(rawCommand))
        let decision: TerminalTelegramPermissionDecision
        switch command {
        case "allow":
            decision = .allowOnce
        case "always":
            decision = .allowAlways
        case "deny":
            decision = .deny
        default:
            return nil
        }

        let requestID = parts
            .dropFirst()
            .first
            .flatMap { normalizedRequestID(String($0)) }
        return TerminalTelegramPermissionCommand(decision: decision, requestID: requestID)
    }

    static func permissionRequestMessage(
        requestID: String,
        request: AgentToolAuthorizationRequest
    ) -> String {
        """
        Permission required
        Request ID: \(requestID)

        ZenCODE wants to run a local command with access to the workspace.

        Directory:
        \(request.workingDirectory)

        Command:
        \(request.command)

        Reply with:
        /allow \(requestID) — allow once
        /always \(requestID) — allow always
        /deny \(requestID) — reject
        """
    }

    private func newRequestID() -> String {
        nextRequestCounter += 1
        let suffix = String(nextRequestCounter, radix: 36, uppercase: true)
        return String(UUID().uuidString.prefix(5)).uppercased() + suffix
    }

    private func makeTimeoutTask(
        requestID: String,
        timeoutNanoseconds: UInt64
    ) -> Task<Void, Never>? {
        guard timeoutNanoseconds > 0 else {
            return nil
        }
        return Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            _ = await self?.resolveRequest(id: requestID, resolution: .timedOut)
        }
    }

    @discardableResult
    private func resolveRequest(
        id requestID: String,
        resolution: TerminalTelegramPermissionResolution
    ) -> Bool {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else {
            return false
        }
        pending.timeoutTask?.cancel()
        pendingRequestIDsByChat[pending.chatID]?.removeAll { $0 == requestID }
        if pendingRequestIDsByChat[pending.chatID]?.isEmpty == true {
            pendingRequestIDsByChat.removeValue(forKey: pending.chatID)
        }
        pending.continuation.resume(returning: resolution)
        return true
    }

    private func pendingRequestIDs(for chatID: Int64) -> [String] {
        pendingRequestIDsByChat[chatID] ?? []
    }

    private static func normalizedCommand(_ rawCommand: String) -> String {
        var command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.hasPrefix("/") {
            command.removeFirst()
        }
        if let botNameStart = command.firstIndex(of: "@") {
            command = String(command[..<botNameStart])
        }
        return command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func normalizedRequestID(_ rawRequestID: String) -> String? {
        let requestID = rawRequestID
            .filter { $0.isLetter || $0.isNumber }
            .uppercased()
        return requestID.isEmpty ? nil : requestID
    }

    private static func permissionResolvedMessage(
        requestID: String,
        decision: TerminalTelegramPermissionDecision
    ) -> String {
        switch decision {
        case .allowOnce:
            return "Permission \(requestID) allowed once. Running command."
        case .allowAlways:
            return "Permission \(requestID) allowed always. Running command."
        case .deny:
            return "Permission \(requestID) denied. Command will not run."
        }
    }

    private static func permissionTimedOutMessage(requestID: String) -> String {
        "Permission \(requestID) timed out. Command will not run."
    }

    private static func pendingPermissionReminder(requestIDs: [String]) -> String {
        """
        Permission request pending.
        Reply with /allow \(requestIDs.first ?? "ID"), /always \(requestIDs.first ?? "ID"), or /deny \(requestIDs.first ?? "ID").
        """
    }

        private static func ambiguousPermissionRequestMessage(requestIDs: [String]) -> String {
        "Multiple permission requests are pending. Include the request ID: \(requestIDs.joined(separator: ", "))."
    }

    private static func noPendingPermissionRequestMessage() -> String {
        "No permission request is pending."
    }


    private static func unknownPermissionRequestMessage(
        requestID: String,
        pendingRequestIDs: [String]
    ) -> String {
        "No pending permission request \(requestID). Pending: \(pendingRequestIDs.joined(separator: ", "))."
    }
}
