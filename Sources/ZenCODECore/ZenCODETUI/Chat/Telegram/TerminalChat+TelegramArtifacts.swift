//
//  TerminalChat+TelegramArtifacts.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    // MARK: - Secure artifacts

    /// Directories whose individually selected files may be exported to the
    /// linked chat. Deliberately narrow: the temporary artifact staging
    /// directory only. Nothing under the repository working directory is a
    /// member, so `/diff` and `/report` materialize a bounded excerpt into
    /// this staging area first and only that excerpt can ever be uploaded.
    nonisolated static var telegramArtifactPolicy: TerminalTelegramArtifactPolicy {
        TerminalTelegramArtifactPolicy(
            allowedDirectories: [Self.telegramArtifactStagingDirectory]
        )
    }

    /// Staging directory for outbound artifacts. Created 0700; excerpts are
    /// written 0600 and removed right after the upload (or refusal).
    nonisolated static var telegramArtifactStagingDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-telegram-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return url
    }

    /// `/diff` materializes the session diff into a bounded staging file and
    /// asks for explicit consent. The repository itself is never uploaded:
    /// only this excerpt, only after confirmation.
    func handleTelegramDiffRequest(origin: TerminalPromptOrigin) async {
        guard let chatID = origin.telegramChatID else { return }
        guard let diffText = telegramSessionDiffText()?.nilIfBlank else {
            await sendTelegramSystemMessage(
                "ZenCODE message: no diff is available for this session yet.",
                to: chatID,
                origin: origin
            )
            return
        }
        guard diffText.utf8.count <= TerminalTelegramMultipartForm.maximumBodyBytes else {
            await sendTelegramSystemMessage(
                "ZenCODE message: the session diff exceeds the Telegram upload budget and cannot be sent.",
                to: chatID,
                origin: origin
            )
            return
        }
        let url = Self.telegramArtifactStagingDirectory
            .appendingPathComponent("session-\(sessionID.prefix(8))-\(UUID().uuidString).diff")
        do {
            try Self.writePrivateArtifact(diffText, to: url)
            await offerTelegramArtifact(
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
            await sendTelegramSystemMessage(
                "ZenCODE message: the diff could not be prepared for upload.",
                to: chatID,
                origin: origin
            )
        }
    }

    /// `/report` offers the most recent report/log file found in the ZenCODE
    /// application support tree, after the policy validates it. No file is
    /// sent or read into memory before consent.
    func handleTelegramReportRequest(origin: TerminalPromptOrigin) async {
        guard let chatID = origin.telegramChatID else { return }
        guard let candidate = Self.latestTelegramReportCandidate(),
              let artifact = try? Self.telegramArtifactPolicy.validated(candidate) else {
            await sendTelegramSystemMessage(
                "ZenCODE message: no exportable report or log file was found.",
                to: chatID,
                origin: origin
            )
            return
        }
        await offerTelegramArtifact(
            artifact,
            chatID: chatID,
            summary: "Send “\(artifact.filename)” as a document?",
            origin: origin
        )
    }

    /// Sends the consent request with the two-button keyboard. The upload
    /// happens only through the explicit callback.
    private func offerTelegramArtifact(
        _ artifact: TerminalTelegramArtifact,
        chatID: Int64,
        summary: String,
        origin: TerminalPromptOrigin
    ) async {
        guard let lease = origin.telegramLease else {
            Self.removeStagedArtifact(at: artifact.fileURL)
            return
        }
        do {
            guard let offerID = try await telegramControlService.offerArtifactConsent(
                artifact: artifact,
                chatID: chatID,
                userID: telegramLinkedUserID ?? 0,
                routeLease: lease,
                cleanupAfterUse: Self.isTelegramStagedArtifact(artifact.fileURL)
            ) else {
                Self.removeStagedArtifact(at: artifact.fileURL)
                await sendTelegramSystemMessage(
                    "ZenCODE message: too many pending file requests. Confirm or cancel one first.",
                    to: chatID,
                origin: origin
                )
                return
            }
            let receipt = await sendTelegramArtifactConsentMessage(
                summary,
                to: chatID,
                replyMarkup: TerminalTelegramArtifactConsentKeyboard.markup(offerID: offerID),
                origin: origin
            )
            if receipt == nil {
                // The request never reached the chat: spend the offer so the
                // consent cannot be used later without a visible prompt.
                await telegramControlService.cancelArtifactConsent(
                    offerID: offerID, chatID: chatID
                )
            }
        } catch {
            await sendTelegramSystemMessage(
                "ZenCODE message: this file cannot be sent (\(error.localizedDescription)).",
                to: chatID,
                origin: origin
            )
        }
    }

    /// Handles the explicit Send/Cancel tap of an artifact consent offer.
    /// Returns `true` when the callback belonged to the consent flow.
    /// Cross-extension visibility: consumed by the ingress dispatcher.
    func handleTelegramArtifactConsentCallback(
        _ data: String,
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        guard let consent = TerminalTelegramArtifactConsentKeyboard
            .action(fromCallbackData: data) else {
            return false
        }
        let offerID = consent.offerID
        guard let lease = origin.telegramLease,
              let fence = telegramWireFence(for: origin) else { return true }
        switch consent.action {
        case .cancel:
            await telegramControlService.cancelArtifactConsent(
                offerID: offerID, chatID: message.chatID
            )
            await sendTelegramSystemMessage(
                "ZenCODE message: file send cancelled.",
                to: message.chatID,
                origin: origin
            )
        case .send:
            // Capture the artifact before the offer is spent, so the staged
            // excerpt can be removed after the attempt either way.
            let stagedURL = await telegramControlService.pendingConsentArtifact(
                offerID: offerID, chatID: message.chatID
            )?.fileURL
            do {
                guard let messageID = try await telegramControlService
                    .sendArtifactWithConsent(
                        offerID: offerID,
                        chatID: message.chatID,
                        userID: message.userID,
                        routeLease: lease,
                        policy: Self.telegramArtifactPolicy,
                        topicID: lease.effectiveMessageThreadID,
                        fence: fence
                    ) else {
                    Self.removeStagedArtifact(at: stagedURL)
                    await sendTelegramSystemMessage(
                        "ZenCODE message: that confirmation expired or no longer matches the file. Ask again with /diff or /report.",
                        to: message.chatID,
                        origin: origin
                    )
                    return true
                }
                _ = messageID
                Self.removeStagedArtifact(at: stagedURL)
                await sendTelegramSystemMessage(
                    "ZenCODE message: file sent.",
                    to: message.chatID,
                    origin: origin
                )
            } catch {
                Self.removeStagedArtifact(at: stagedURL)
                await sendTelegramSystemMessage(
                    "ZenCODE message: the file could not be sent (\(error.localizedDescription)).",
                    to: message.chatID,
                    origin: origin
                )
            }
        }
        return true
    }

    /// Removes a staged outbound excerpt after its upload attempt. Only files
    /// inside the private staging directory are ever deleted: operator-owned
    /// report/log files under application support stay untouched.
    private nonisolated static func removeStagedArtifact(at url: URL?) {
        guard let url else { return }
        let staging = telegramArtifactStagingDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target == staging || target.hasPrefix(staging + "/") else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func isTelegramStagedArtifact(_ url: URL) -> Bool {
        let staging = telegramArtifactStagingDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target.hasPrefix(staging + "/")
    }

    /// Selective ingress: an admitted attachment is downloaded into the
    /// bounded 0600 store and acknowledged. The file is never opened by this
    /// path — the operator asks the agent to read it explicitly afterwards.
    func handleTelegramInboundAttachment(
        _ attachment: TerminalTelegramInboundAttachment,
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
    ) async {
        if onTelegramWorkEffectForTesting?(.attachmentDownload) == true { return }
        guard let fence = telegramWireFence(for: origin) else { return }
        do {
            let stored = try await telegramControlService.receiveInboundAttachment(
                attachment, chatID: message.chatID, fence: fence
            )
            await sendTelegramSystemMessage(
                "ZenCODE message: received “\(stored.filename)” (\(stored.mimeType)). Ask the agent to read it by path when needed; it will be removed automatically.",
                to: message.chatID,
                origin: origin
            )
        } catch TerminalTelegramControlError.attachmentStoreBusy {
            await sendTelegramSystemMessage(
                "ZenCODE message: too many attachments are being received. Try again shortly.",
                to: message.chatID,
                origin: origin
            )
        } catch TerminalTelegramControlError.fileTooLarge(let limit) {
            await sendTelegramSystemMessage(
                TerminalTelegramInboundAttachmentGate.Refusal
                    .tooLarge(limit: limit).operatorMessage,
                to: message.chatID,
                origin: origin
            )
        } catch {
            await sendTelegramSystemMessage(
                "ZenCODE message: the attachment could not be received.",
                to: message.chatID,
                origin: origin
            )
        }
    }

    /// Bounded session diff text assembled from the per-file patches the
    /// session already holds, or `nil` when none exists. The excerpt is
    /// capped by the multipart budget so a giant working tree can never
    /// produce an unbounded artifact.
    private func telegramSessionDiffText() -> String? {
        guard let summary = lastFileChangeSummary, !summary.entries.isEmpty else {
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

    /// Most recent exportable report/log candidate under application support.
    private nonisolated static func latestTelegramReportCandidate() -> TerminalTelegramArtifact? {
        let fileManager = FileManager.default
        let roots = [
            AppStorageDirectory.appSupportDirectoryURL(),
            fileManager.temporaryDirectory,
        ]
        let allowed = Set(["log", "txt", "md", "json"])
        var best: (url: URL, date: Date)?
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                ), values.isRegularFile == true,
                    allowed.contains(url.pathExtension.lowercased()) else {
                    continue
                }
                let date = values.contentModificationDate ?? .distantPast
                if best == nil || date > best!.date {
                    best = (url, date)
                }
            }
        }
        guard let best else { return nil }
        return TerminalTelegramArtifact(
            fileURL: best.url,
            filename: best.url.lastPathComponent
        )
    }

    /// Plain-text send with a reply markup, returning the receipt, so consent
    /// keyboards never inherit Markdown parsing from operator-typed names.
    private func sendTelegramArtifactConsentMessage(
        _ text: String,
        to chatID: Int64,
        replyMarkup: TerminalTelegramReplyMarkup,
        origin: TerminalPromptOrigin
    ) async -> Int? {
        if let onTelegramSystemMessage {
            _ = await onTelegramSystemMessage(text, chatID)
            return nil
        }
        guard let fence = telegramWireFence(for: origin) else { return nil }
        do {
            return try await telegramControlService.sendPlainMessageWithReceipt(
                text, to: chatID, topicID: origin.telegramLease?.effectiveMessageThreadID,
                replyMarkup: replyMarkup, fence: fence
            )
        } catch {
            telegramControlState.lastError = error.localizedDescription
            return nil
        }
    }
}
