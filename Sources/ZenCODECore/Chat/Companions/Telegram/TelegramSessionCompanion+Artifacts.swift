//
//  TelegramSessionCompanion+Artifacts.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// `/diff`, the explicit Send/Cancel consent of an outbound artifact, and the
/// selective ingress of documents and images.
extension TelegramSessionCompanion {
    // MARK: - Secure artifacts

    /// The terminal's staging directory for outbound artifacts, the default
    /// of ``artifactStagingDirectory``.
    nonisolated static var defaultArtifactStagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-telegram-artifacts", isDirectory: true)
    }

    /// ``artifactStagingDirectory``, created 0700 when missing. Excerpts are
    /// written 0600 inside it and removed right after the upload (or
    /// refusal).
    var preparedArtifactStagingDirectory: URL {
        let url = artifactStagingDirectory
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return url
    }

    /// Directories whose individually selected files may be exported to the
    /// linked chat. Deliberately narrow: the temporary artifact staging
    /// directory only. Nothing under the repository working directory is a
    /// member, so `/diff` materializes a bounded excerpt into this staging
    /// area first and only that excerpt can ever be uploaded.
    var artifactPolicy: TerminalTelegramArtifactPolicy {
        TerminalTelegramArtifactPolicy(
            allowedDirectories: [preparedArtifactStagingDirectory]
        )
    }

    /// `/diff` materializes the session diff into a bounded staging file and
    /// asks for explicit consent. The repository itself is never uploaded:
    /// only this excerpt, only after confirmation.
    func handleDiffRequest(origin: TelegramTurnOrigin) async {
        guard let chatID = origin.lease?.key.chatID else { return }
        guard let diffText = sessionDiffText()?.nilIfBlank else {
            await sendSystemMessage(
                "ZenCODE message: no diff is available for this session yet.",
                to: chatID,
                origin: origin
            )
            return
        }
        guard diffText.utf8.count <= TerminalTelegramMultipartForm.maximumBodyBytes else {
            await sendSystemMessage(
                "ZenCODE message: the session diff exceeds the Telegram upload budget and cannot be sent.",
                to: chatID,
                origin: origin
            )
            return
        }
        let url = preparedArtifactStagingDirectory
            .appendingPathComponent("session-\(controller.sessionID.prefix(8))-\(UUID().uuidString).diff")
        do {
            try Self.writePrivateArtifact(diffText, to: url)
            await offerArtifact(
                TerminalTelegramArtifact(
                    fileURL: url,
                    filename: url.lastPathComponent,
                    contentType: "text/x-diff"
                ),
                chatID: chatID,
                summary: "Send the session diff as a document?",
                origin: origin
            )
        } catch {
            // writePrivateArtifact failed: no offer exists, so the service never
            // owned the file. Remove any partial excerpt.
            removeStagedArtifact(at: url)
            await sendSystemMessage(
                "ZenCODE message: the diff could not be prepared for upload.",
                to: chatID,
                origin: origin
            )
        }
    }

    /// Sends the consent request with the two-button keyboard. The upload
    /// happens only through the explicit callback.
    private func offerArtifact(
        _ artifact: TerminalTelegramArtifact,
        chatID: Int64,
        summary: String,
        origin: TelegramTurnOrigin
    ) async {
        guard let lease = origin.lease else {
            removeStagedArtifact(at: artifact.fileURL)
            return
        }
        do {
            guard let offerID = try await controlService.offerArtifactConsent(
                artifact: artifact,
                chatID: chatID,
                userID: linkedUserID ?? 0,
                routeLease: lease,
                cleanupAfterUse: isStagedArtifact(artifact.fileURL)
            ) else {
                removeStagedArtifact(at: artifact.fileURL)
                await sendSystemMessage(
                    "ZenCODE message: too many pending file requests. Confirm or cancel one first.",
                    to: chatID,
                    origin: origin
                )
                return
            }
            let receipt = await sendArtifactConsentMessage(
                summary,
                to: chatID,
                replyMarkup: TerminalTelegramArtifactConsentKeyboard.markup(offerID: offerID),
                origin: origin
            )
            if receipt == nil {
                // The request never reached the chat: spend the offer so the
                // consent cannot be used later without a visible prompt.
                await controlService.cancelArtifactConsent(
                    offerID: offerID, chatID: chatID
                )
            }
        } catch {
            // The offer was never registered (the service threw before taking
            // ownership), so the staged excerpt is still ours to remove.
            removeStagedArtifact(at: artifact.fileURL)
            await sendSystemMessage(
                "ZenCODE message: this file cannot be sent (\(TerminalTelegramControlError.operatorDescription(error))).",
                to: chatID,
                origin: origin
            )
        }
    }

    /// Handles the explicit Send/Cancel tap of an artifact consent offer.
    /// Returns `true` when the callback belonged to the consent flow. The
    /// channel's ingress calls it for every callback query.
    func handleArtifactConsentCallback(
        _ data: String,
        message: TerminalTelegramIncomingMessage,
        origin: TelegramTurnOrigin
    ) async -> Bool {
        guard let consent = TerminalTelegramArtifactConsentKeyboard
            .action(fromCallbackData: data) else {
            return false
        }
        let offerID = consent.offerID
        guard let lease = origin.lease,
              let fence = wireFence(for: origin) else { return true }
        switch consent.action {
        case .cancel:
            await controlService.cancelArtifactConsent(
                offerID: offerID, chatID: message.chatID
            )
            await sendSystemMessage(
                "ZenCODE message: file send cancelled.",
                to: message.chatID,
                origin: origin
            )
        case .send:
            // Once the offer is registered the control service owns the staged
            // excerpt: it deletes it after consume (sent, refused or failed),
            // on cancel, on expiry and on reset. The companion never deletes
            // it here.
            do {
                guard let messageID = try await controlService
                    .sendArtifactWithConsent(
                        offerID: offerID,
                        chatID: message.chatID,
                        userID: message.userID,
                        routeLease: lease,
                        policy: artifactPolicy,
                        topicID: lease.effectiveMessageThreadID,
                        fence: fence
                    ) else {
                    await sendSystemMessage(
                        "ZenCODE message: that confirmation expired or no longer matches the file. Ask again with /diff.",
                        to: message.chatID,
                        origin: origin
                    )
                    return true
                }
                _ = messageID
                await sendSystemMessage(
                    "ZenCODE message: file sent.",
                    to: message.chatID,
                    origin: origin
                )
            } catch {
                // Failures before the offer was consumed (e.g. wire fence)
                // leave it pending: spend it so the service removes the file.
                await controlService.cancelArtifactConsent(
                    offerID: offerID, chatID: message.chatID
                )
                await sendSystemMessage(
                    "ZenCODE message: the file could not be sent (\(TerminalTelegramControlError.operatorDescription(error))).",
                    to: message.chatID,
                    origin: origin
                )
            }
        }
        return true
    }

    /// Removes a staged outbound excerpt after its upload attempt. Only files
    /// inside the private staging directory are ever deleted: operator-owned
    /// files elsewhere stay untouched.
    private func removeStagedArtifact(at url: URL?) {
        guard let url else { return }
        let staging = preparedArtifactStagingDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target == staging || target.hasPrefix(staging + "/") else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func isStagedArtifact(_ url: URL) -> Bool {
        let staging = preparedArtifactStagingDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target.hasPrefix(staging + "/")
    }

    // MARK: - Inbound attachments

    /// Selective ingress: an admitted attachment is downloaded into the
    /// bounded 0600 store and acknowledged. The file is never opened by this
    /// path — the operator asks the agent to read it explicitly afterwards.
    func handleInboundAttachment(
        _ attachment: TerminalTelegramInboundAttachment,
        message: TerminalTelegramIncomingMessage,
        origin: TelegramTurnOrigin
    ) async {
        if onTelegramWorkEffectForTesting?(.attachmentDownload) == true { return }
        guard let fence = wireFence(for: origin) else { return }
        do {
            let stored = try await controlService.receiveInboundAttachment(
                attachment, chatID: message.chatID, fence: fence
            )
            await sendSystemMessage(
                "ZenCODE message: received “\(stored.filename)” (\(stored.mimeType)). Ask the agent to read it by path when needed; it will be removed automatically.",
                to: message.chatID,
                origin: origin
            )
        } catch TerminalTelegramControlError.attachmentStoreBusy {
            await sendSystemMessage(
                "ZenCODE message: too many attachments are being received. Try again shortly.",
                to: message.chatID,
                origin: origin
            )
        } catch TerminalTelegramControlError.fileTooLarge(let limit) {
            await sendSystemMessage(
                TerminalTelegramInboundAttachmentGate.Refusal
                    .tooLarge(limit: limit).operatorMessage,
                to: message.chatID,
                origin: origin
            )
        } catch {
            await sendSystemMessage(
                "ZenCODE message: the attachment could not be received.",
                to: message.chatID,
                origin: origin
            )
        }
    }

    // MARK: - Support

    /// Bounded session diff text assembled from the per-file patches the
    /// session already holds, or `nil` when none exists. The excerpt is
    /// capped by the multipart budget so a giant working tree can never
    /// produce an unbounded artifact.
    func sessionDiffText() -> String? {
        guard let summary = controller.lastFileChangeSummary, !summary.entries.isEmpty else {
            return nil
        }
        let budget = TerminalTelegramMultipartForm.maximumBodyBytes
        var lines: [String] = []
        var count = 0
        for entry in summary.entries {
            let patch = entry.patch?.nilIfBlank
                ?? "\(entry.status.rawValue) \(entry.path) (+\(entry.additions) -\(entry.deletions))"
            let block = patch.hasSuffix("\n") ? patch : patch + "\n"
            count += block.utf8.count
            if count > budget { break }
            lines.append(block)
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined()
    }

    private nonisolated static func writePrivateArtifact(
        _ text: String, to url: URL
    ) throws {
        let data = Data(text.utf8)
        let succeeded = FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        )
        guard succeeded else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Plain-text send with a reply markup, returning the receipt, so consent
    /// keyboards never inherit Markdown parsing from operator-typed names.
    private func sendArtifactConsentMessage(
        _ text: String,
        to chatID: Int64,
        replyMarkup: TerminalTelegramReplyMarkup,
        origin: TelegramTurnOrigin
    ) async -> Int? {
        if let onTelegramSystemMessage {
            _ = await onTelegramSystemMessage(text, chatID)
            return nil
        }
        guard let fence = wireFence(for: origin) else { return nil }
        do {
            return try await controlService.sendPlainMessageWithReceipt(
                text, to: chatID, topicID: origin.lease?.effectiveMessageThreadID,
                replyMarkup: replyMarkup, fence: fence
            )
        } catch {
            controlState.lastError = TerminalTelegramControlError.operatorDescription(error)
            return nil
        }
    }
}
