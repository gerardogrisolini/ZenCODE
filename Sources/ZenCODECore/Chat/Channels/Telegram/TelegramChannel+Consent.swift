//
//  TelegramChannel+Consent.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The interaction host of a ``TelegramChannel``: the slot's host forwards
/// the controller's questions here while the channel drives the slot (see
/// ``ChatSlotInteractionHost``), and moves the ones still open to the primary
/// channel when `/telegram off` takes the slot back.
///
/// Tool consent is asked in the linked chat with the permission broker's
/// card and answered with `/allow`, `/always` or `/deny`; the decision goes
/// back to the ``ChatToolConsentAuthorizer`` of the incarnation, which
/// records an *Always* exactly as one given on the primary channel, so it
/// keeps covering the session after the link or the topic changes. A line of
/// text is the next text message of the chat, an attachment the next
/// document or image; menus are not offered. Workspace access is asked with
/// the same card, as a permission to use the folder. The conformance is
/// declared with the class; the host's methods live here.
extension TelegramChannel {
    nonisolated public var capabilities: ChatChannelCapabilities {
        [.toolConsent, .textInput, .attachmentPicker]
    }

    // MARK: - Tool consent

    public func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        guard let lease = activeRouteLease,
              let chatID = outgoingChatID(for: lease),
              await validateLease(lease) else {
            await presentNotice(
                "ZenCODE: Telegram cannot request permission for \(request.toolName); the operation was denied.\n",
                channel: .failure
            )
            return nil
        }
        let send: @Sendable (String) async -> Bool = { [weak self] message in
            guard let self, await self.validateLease(lease) else { return false }
            return await self.sendTurnMessage(.authorization(message), to: chatID, lease: lease)
        }
        let outcome = await permissionBroker.authorize(request, lease: lease, sendMessage: send)
        await presentTelegramPermissionOutcome(outcome, request: request)
        switch outcome {
        case .notRequired, .allowedOnce:
            return .allowOnce
        case .allowedAlways:
            return .allowAlways
        case .denied:
            return .denyOnce
        case .timedOut, .undeliverable, .cancelled:
            return nil
        }
    }

    /// Answers a permission reply (`/allow`, `/always`, `/deny`) that
    /// arrived on `lease`, returning `true` when the text was a permission
    /// reply or a reply to a pending permission request, so it must not run
    /// as a prompt. A reply on a route that is no longer valid is consumed
    /// without effect. The broker's answer goes to the linked chat on the
    /// turn's ordered channel.
    func handlePermissionResponseIfNeeded(
        _ text: String,
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        guard (try? await router.validate(lease)) != nil else { return true }
        let result = await permissionBroker.handleMessage(text, lease: lease)
        switch result {
        case .notHandled:
            return false
        case let .handled(reply):
            if let reply = reply?.nilIfBlank {
                await sendTurnMessage(.authorization(reply), to: lease.key.chatID, lease: lease)
            }
            return true
        }
    }

    /// Tells the primary channel how the linked chat decided, as the
    /// terminal was told while it shared the decision.
    private func presentTelegramPermissionOutcome(
        _ outcome: TerminalTelegramPermissionOutcome,
        request: AgentToolAuthorizationRequest
    ) async {
        switch outcome {
        case .notRequired:
            // A previous decision already covered the request; nothing was asked.
            break
        case .allowedOnce, .allowedAlways:
            await presentNotice("Telegram approved \(request.toolName).\n", channel: .system)
        case .denied:
            await presentNotice("Telegram denied \(request.toolName).\n", channel: .system)
        case .timedOut:
            await presentNotice(
                "ZenCODE: Telegram permission for \(request.toolName) timed out; the operation was denied.\n",
                channel: .failure
            )
        case .undeliverable:
            await presentNotice(
                "ZenCODE: the Telegram permission request for \(request.toolName) could not be delivered; the operation was denied.\n",
                channel: .failure
            )
        case .cancelled:
            break
        }
    }

    // MARK: - Workspace access

    public func requestWorkspaceAccess(_ request: ChatWorkspaceAccessRequest) async -> Bool {
        let tools = request.toolTitles.joined(separator: ", ")
        let consent = await requestToolConsent(AgentToolAuthorizationRequest(
            turnID: nil,
            sessionID: sessionID,
            toolCallID: "workspace-access-\(UUID().uuidString)",
            toolName: "workspace.access",
            title: "Allow the session's tools to use \(request.workspaceURL.path)"
                + (tools.isEmpty ? "" : " (\(tools))"),
            kind: "workspace",
            command: request.workspaceURL.path,
            workingDirectory: request.workspaceURL.path
        ))
        switch consent {
        case .allowOnce, .allowAlways:
            return true
        case .denyOnce, .denyAlways, nil:
            return false
        }
    }

    // MARK: - Text and attachments

    public func readLine(prompt: String) async -> String? {
        guard let lease = activeRouteLease, await validateLease(lease) else { return nil }
        await sendSystemMessageIfLinked(
            "\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))\nReply with your answer as text.",
            lease: lease
        )
        return await waitForNextLine(on: lease)
    }

    public func pickAttachment(startingAt directory: URL) async -> URL? {
        guard let lease = activeRouteLease, await validateLease(lease) else { return nil }
        await sendSystemMessageIfLinked(
            "Send the document or image to attach to the next prompt.",
            lease: lease
        )
        return await waitForNextAttachment(on: lease)
    }

    /// Waits for the next text message of the chat on `lease`, which the
    /// ingress delivers to the reader instead of running it (see
    /// ``deliverPendingLine(_:lease:)``). A reader already waiting is
    /// refused: one question at a time.
    private func waitForNextLine(on lease: TerminalTelegramRouteLease) async -> String? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, pendingLineReader == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                pendingLineReader = PendingReader(id: id, lease: lease, continuation: continuation)
            }
        } onCancel: {
            Task { @ChatSessionActor in
                self.cancelPendingLineReader(id: id)
            }
        }
    }

    /// Waits for the next document or image of the chat on `lease`, which
    /// the ingress hands to the reader once it is stored.
    private func waitForNextAttachment(on lease: TerminalTelegramRouteLease) async -> URL? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, pendingAttachmentReader == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                pendingAttachmentReader = PendingReader(id: id, lease: lease, continuation: continuation)
            }
        } onCancel: {
            Task { @ChatSessionActor in
                self.cancelPendingAttachmentReader(id: id)
            }
        }
    }

    /// Delivers `text`, a message that arrived on `lease`, to the reader
    /// waiting for a line, and returns whether one took it.
    func deliverPendingLine(_ text: String, lease: TerminalTelegramRouteLease) -> Bool {
        guard let reader = pendingLineReader, reader.lease.key.chatID == lease.key.chatID else {
            return false
        }
        pendingLineReader = nil
        reader.continuation.resume(returning: text)
        return true
    }

    /// Delivers `url`, a document or image stored from `lease`, to the
    /// reader waiting for an attachment, and returns whether one took it.
    func deliverPendingAttachment(_ url: URL, lease: TerminalTelegramRouteLease) -> Bool {
        guard let reader = pendingAttachmentReader, reader.lease.key.chatID == lease.key.chatID else {
            return false
        }
        pendingAttachmentReader = nil
        reader.continuation.resume(returning: url)
        return true
    }

    /// Whether a question waits for the next message of the chat.
    var hasPendingReader: Bool {
        pendingLineReader != nil || pendingAttachmentReader != nil
    }

    /// Refuses the readers still waiting: the channel stops reading the chat.
    func cancelPendingReaders() {
        if let reader = pendingLineReader {
            pendingLineReader = nil
            reader.continuation.resume(returning: nil)
        }
        if let reader = pendingAttachmentReader {
            pendingAttachmentReader = nil
            reader.continuation.resume(returning: nil)
        }
    }

    private func cancelPendingLineReader(id: UUID) {
        guard let reader = pendingLineReader, reader.id == id else { return }
        pendingLineReader = nil
        reader.continuation.resume(returning: nil)
    }

    private func cancelPendingAttachmentReader(id: UUID) {
        guard let reader = pendingAttachmentReader, reader.id == id else { return }
        pendingAttachmentReader = nil
        reader.continuation.resume(returning: nil)
    }
}
