//
//  TerminalTelegramPermissionBroker.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 11/06/26.
//

import Foundation
import ToolCore

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

/// Outcome of a remote authorization request.
///
/// The handler contract is a `Bool`, but the terminal needs the reason behind a
/// refusal to tell the local operator whether the remote user declined, never
/// answered, or never received the request at all.
enum TerminalTelegramPermissionOutcome: Sendable, Equatable {
    /// The tool is not gated, or a previous decision already covers it.
    case notRequired
    case allowedOnce
    case allowedAlways
    case denied
    case timedOut
    /// The request could not be delivered to Telegram, so nobody could answer it.
    case undeliverable
    case cancelled

    var isApproved: Bool {
        switch self {
        case .notRequired, .allowedOnce, .allowedAlways:
            return true
        case .denied, .timedOut, .undeliverable, .cancelled:
            return false
        }
    }
}

private enum TerminalTelegramPermissionResolution: Sendable, Equatable {
    case decision(TerminalTelegramPermissionDecision)
    case timedOut
    case undeliverable
    case cancelled
}

actor TerminalTelegramPermissionBroker {
    static let defaultTimeoutNanoseconds: UInt64 = 600_000_000_000

    private enum Scope: Hashable, Sendable {
        case legacyChat(Int64)
        case route(TerminalTelegramRouteLease)
    }

    private struct PendingRequest {
        let id: String
        let scope: Scope
        let request: AgentToolAuthorizationRequest
        let continuation: CheckedContinuation<TerminalTelegramPermissionResolution, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private var nextRequestCounter = 0
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingRequestIDsByScope: [Scope: [String]] = [:]
    /// Session-scoped "always" decisions, keyed exactly like the terminal
    /// authorizer's cache so the same command approved remotely is not asked
    /// again through a different surface.
    private var alwaysAllowedKeysByScope: [Scope: Set<String>] = [:]

    /// Returns `true` when this request needs no remote dialogue: either the
    /// tool is not gated, or a previous decision already covers it.
    func isAlreadyAuthorized(_ request: AgentToolAuthorizationRequest) -> Bool {
        isAlreadyAuthorized(request, scope: .legacyChat(0))
    }

    func isAlreadyAuthorized(
        _ request: AgentToolAuthorizationRequest,
        lease: TerminalTelegramRouteLease
    ) -> Bool {
        isAlreadyAuthorized(request, scope: .route(lease))
    }

    private func isAlreadyAuthorized(
        _ request: AgentToolAuthorizationRequest,
        scope: Scope
    ) -> Bool {
        guard LocalExecPermissionAuthorizer.gatedToolNames.contains(request.toolName) else {
            return true
        }
        let allowed = alwaysAllowedKeysByScope[scope] ?? []
        if Self.permissionCacheKeys(for: request).allSatisfy(allowed.contains) {
            return true
        }
        return request.toolName == "local.exec"
            && LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(request.command)
    }

    /// Requests remote authorization for a gated tool call.
    ///
    /// The gated set is the terminal authorizer's set — shell commands plus the
    /// destructive direct tools — so a remote turn cannot silently perform an
    /// operation that a local turn would have to confirm.
    func authorize(
        _ request: AgentToolAuthorizationRequest,
        chatID: Int64,
        timeoutNanoseconds: UInt64 = TerminalTelegramPermissionBroker.defaultTimeoutNanoseconds,
        sendMessage: @escaping @Sendable (String) async -> Bool
    ) async -> TerminalTelegramPermissionOutcome {
        await authorize(
            request, scope: .legacyChat(chatID), timeoutNanoseconds: timeoutNanoseconds,
            sendMessage: sendMessage
        )
    }

    func authorize(
        _ request: AgentToolAuthorizationRequest,
        lease: TerminalTelegramRouteLease,
        timeoutNanoseconds: UInt64 = TerminalTelegramPermissionBroker.defaultTimeoutNanoseconds,
        sendMessage: @escaping @Sendable (String) async -> Bool
    ) async -> TerminalTelegramPermissionOutcome {
        await authorize(
            request, scope: .route(lease), timeoutNanoseconds: timeoutNanoseconds,
            sendMessage: sendMessage
        )
    }

    private func authorize(
        _ request: AgentToolAuthorizationRequest,
        scope: Scope,
        timeoutNanoseconds: UInt64,
        sendMessage: @escaping @Sendable (String) async -> Bool
    ) async -> TerminalTelegramPermissionOutcome {
        guard !isAlreadyAuthorized(request, scope: scope) else {
            return .notRequired
        }
        let cacheKeys = Self.permissionCacheKeys(for: request)

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
                        scope: scope,
                        request: request,
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
                    pendingRequestIDsByScope[scope, default: []].append(requestID)

                    let message = Self.permissionRequestMessage(
                        requestID: requestID,
                        request: request,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                    Task(name: "ZenCODE.Telegram.permission-request") {
                        // A request nobody received must fail closed at once
                        // instead of holding the turn until the timeout.
                        guard await sendMessage(message) else {
                            self.resolveRequest(
                                id: requestID,
                                resolution: .undeliverable
                            )
                            return
                        }
                    }
                }
            },
            onCancel: {
                Task(name: "ZenCODE.Telegram.permission-cancellation") {
                    await self.resolveRequest(id: requestID, resolution: .cancelled)
                }
            }
        )

        switch resolution {
        case .decision(.allowOnce):
            return .allowedOnce
        case .decision(.allowAlways):
            alwaysAllowedKeysByScope[scope, default: []].formUnion(cacheKeys)
            if request.toolName == "local.exec", case .legacyChat = scope {
                LocalExecPermissionAuthorizer.persistAllowedCommand(request.command)
            }
            return .allowedAlways
        case .decision(.deny):
            return .denied
        case .cancelled:
            return .cancelled
        case .undeliverable:
            return .undeliverable
        case .timedOut:
            _ = await sendMessage(Self.permissionTimedOutMessage(requestID: requestID))
            return .timedOut
        }
    }

    /// Mirrors ``LocalExecPermissionAuthorizer``'s cache identity so both
    /// surfaces agree on what a previous "always" decision already covers.
    private static func permissionCacheKeys(
        for request: AgentToolAuthorizationRequest
    ) -> [String] {
        let identities: [String]
        if request.toolName == "local.exec" {
            let parsedIdentities = LocalExecPermissionAuthorizer
                .localExecPermissionCacheIdentities(for: request.command)
            identities = parsedIdentities.isEmpty ? [request.command] : parsedIdentities
        } else {
            identities = [request.command]
        }
        return identities.map {
            LocalExecPermissionAuthorizer.permissionCacheKey(
                toolName: request.toolName,
                identity: $0
            )
        }
    }

    func handleMessage(
        _ text: String,
        chatID: Int64
    ) -> TerminalTelegramPermissionMessageResult {
        handleMessage(text, scope: .legacyChat(chatID))
    }

    func handleMessage(
        _ text: String,
        lease: TerminalTelegramRouteLease
    ) -> TerminalTelegramPermissionMessageResult {
        handleMessage(text, scope: .route(lease))
    }

    private func handleMessage(
        _ text: String,
        scope: Scope
    ) -> TerminalTelegramPermissionMessageResult {
        let pendingIDs = pendingRequestIDs(for: scope)
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
        request: AgentToolAuthorizationRequest,
        timeoutNanoseconds: UInt64 = TerminalTelegramPermissionBroker.defaultTimeoutNanoseconds
    ) -> String {
        var lines = [
            "🔐 Permission required",
            "Request ID: \(requestID)",
            "",
            request.title.nilIfBlank ?? "ZenCODE wants to run a gated operation.",
            "",
            "Tool:",
            request.toolName,
            "",
            "Directory:",
            request.workingDirectory,
            "",
            "Command:",
            request.command,
            ""
        ]
        if let deadline = Self.timeoutDescription(timeoutNanoseconds) {
            lines.append("Reply within \(deadline):")
        } else {
            lines.append("Reply with:")
        }
        lines.append(contentsOf: [
            "/allow \(requestID) — allow once",
            "/always \(requestID) — allow always",
            "/deny \(requestID) — reject"
        ])
        return lines.joined(separator: "\n")
    }

    private static func timeoutDescription(_ timeoutNanoseconds: UInt64) -> String? {
        guard timeoutNanoseconds > 0 else {
            return nil
        }
        let seconds = Int(timeoutNanoseconds / 1_000_000_000)
        guard seconds >= 60 else {
            return seconds <= 0 ? nil : "\(seconds)s"
        }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
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
        return Task(name: "ZenCODE.Telegram.permission-timeout") { [weak self] in
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
        pendingRequestIDsByScope[pending.scope]?.removeAll { $0 == requestID }
        if pendingRequestIDsByScope[pending.scope]?.isEmpty == true {
            pendingRequestIDsByScope.removeValue(forKey: pending.scope)
        }
        pending.continuation.resume(returning: resolution)
        return true
    }

    private func pendingRequestIDs(for scope: Scope) -> [String] {
        pendingRequestIDsByScope[scope] ?? []
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
            return "✅ Permission \(requestID) allowed once. Continuing."
        case .allowAlways:
            return "✅ Permission \(requestID) allowed always. Continuing."
        case .deny:
            return "⛔ Permission \(requestID) denied. The operation will not run."
        }
    }

    private static func permissionTimedOutMessage(requestID: String) -> String {
        "⌛ Permission \(requestID) timed out. The operation will not run."
    }

    private static func pendingPermissionReminder(requestIDs: [String]) -> String {
        """
        🔐 Permission request pending.
        Reply with /allow \(requestIDs.first, default: "ID"), /always \(requestIDs.first, default: "ID"), or /deny \(requestIDs.first, default: "ID").
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
