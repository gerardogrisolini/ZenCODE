//
//  TerminalChat+TelegramLifecycle.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    func writeTelegramSubmittedPrompt(_ prompt: String) async {
        let title = telegramLinkedChatTitle?.nilIfBlank ?? "Telegram"
        await writeSystemMessage("\n\(title) sent a prompt:\n")
        await writeSubmittedPrompt(prompt)
    }

    func startTelegramControl() async {
        guard stdinIsTerminal else {
            await writeFailureMessage("ZenCODE: /telegram requires the interactive TUI.\n")
            return
        }
        guard isTelegramConfigured() else {
            await writeFailureMessage(Self.unknownCommandMessage(for: "/telegram"))
            return
        }
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              let linkedChatID = settings.linkedChatID else {
            await writeFailureMessage("ZenCODE: Telegram is not paired. Run the /setup command in zen.\n")
            return
        }

        do {
            guard let lease = await telegramEgressRouteLease(
                settings: settings,
                linkedChatID: linkedChatID
            ) else {
                await writeFailureMessage(
                    "ZenCODE: Telegram configuration is invalid. Run /setup to pair Telegram again.\n"
                )
                return
            }
            telegramLinkedChatID = linkedChatID
            telegramLinkedChatTitle = settings.linkedChatTitle
            telegramLinkedUserID = lease.key.userID
            telegramActiveRouteLease = lease
            telegramControlState = try await telegramControlService.start()
            // A local turn that was already running while Telegram was off
            // must use the same validated lease as the next local turn.
            if activeTelegramTurnOrigin == .local {
                activeTelegramTurnOrigin = .telegramLease(lease)
            }
            telegramVoiceTranscriptions.resume()
            await synchronizeTelegramTurnProgressReporting()
            let chatTitle = telegramLinkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
            await writeSystemMessage(
                """
                Telegram remote control is active.
                Linked chat: \(chatTitle)

                """
            )
            // Unsupported, ownerless or incoherent settings remain fail-closed
            // until setup creates a complete schema-2 owner route.
        } catch {
            telegramControlState = await telegramControlService.currentState()
            telegramControlState.lastError = error.localizedDescription
            await synchronizeTelegramTurnProgressReporting()
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    /// Restores the owner-bearing route persisted by setup so `/telegram on`
    /// enables egress immediately, without requiring a fresh Telegram message.
    ///
    /// The route is resolved through the owner authority rather than synthesized
    /// from `linkedChatID`; every later wire operation therefore retains the
    /// generation and lifecycle validation introduced by multi-session routing.
    func telegramEgressRouteLease(
        settings: AgentTelegramSettingsManifest,
        linkedChatID: Int64
    ) async -> TerminalTelegramRouteLease? {
        guard settings.isRoutingSupported else { return nil }
        await telegramSessionRouter.refresh(
            linkedChatID: settings.linkedChatID,
            ownerUserID: settings.ownerUserID,
            routes: settings.routes
        )
        let candidates = settings.routes.filter {
            $0.topicID == nil
                && $0.lifecycle == .active
                && ($0.roomID == sessionID || $0.roomID == "default")
        }
        guard candidates.count == 1, settings.linkedChatID == linkedChatID,
              let ownerUserID = settings.ownerUserID else { return nil }
        return try? await telegramSessionRouter.resolve(
            chatID: linkedChatID,
            userID: ownerUserID,
            topicID: nil
        )
    }

    func stopTelegramControl() async {
        // Disconnect the current turn before hopping to the service actor, so
        // events emitted while `stop()` is in flight cannot enqueue more output.
        telegramControlState.isActive = false
        await telegramVoiceTranscriptions.cancelAllAndWait()
        let validationTask = telegramRouteValidationTask
        telegramRouteValidationTask = nil
        validationTask?.cancel()
        await validationTask?.value
        let reporter = activeTelegramProgressReporter
        activeTelegramProgressReporter = nil
        if let reporter { await reporter.shutdown() }
        if let presence = activeTelegramPresenceLease {
            await telegramControlService.releasePresenceLease(presence)
            activeTelegramPresenceLease = nil
        }
        if let lease = activeTelegramTurnOrigin?.telegramLease {
            await telegramRouteRuntimeState.teardown(lease: lease)
        }
        // Unbind before stopping the transport so no card is queued for a chat
        // that is about to be released. The ledger is retained on purpose.
        await telegramSharedChatRelay.deactivate()
        telegramControlState = await telegramControlService.stop()
        telegramActiveRouteLease = nil
        telegramLinkedChatID = nil
        telegramLinkedChatTitle = nil
        telegramLinkedUserID = nil
        // Deterministic inbound-attachment teardown: every received temporary
        // is deleted and every pending upload consent is dropped.
        _ = await telegramControlService.cleanupInboundAttachments()
        await writeSystemMessage("Telegram remote control stopped.\n")
    }

    func printTelegramStatus() async {
        telegramControlState = await telegramControlService.currentState()
        await writeSystemMessage(telegramStatusText() + "\n")
    }

    /// Starts tracking a turn even when Telegram is currently disabled. Keeping
    /// the origin lets `/telegram on` attach a reporter to an already-running
    /// local request; previously the reporter was a one-time snapshot created at
    /// turn start, so enabling Telegram mid-turn had no effect.
    func beginTelegramTurnProgressReporting(for origin: TerminalPromptOrigin) async {
        let previousValidationTask = telegramRouteValidationTask
        telegramRouteValidationTask = nil
        previousValidationTask?.cancel()
        await previousValidationTask?.value
        await activeTelegramProgressReporter?.revokeAndWait()
        activeTelegramProgressReporter = nil
        activeTelegramTurnOrigin = origin
        resetTelegramRootResponseBlock()
        resetMirroredOverviewSignatures()
        // Fence off any undelivered mirror notification from the previous
        // turn before the new turn's reporter exists: stale-epoch deliveries
        // are discarded instead of being adopted by the new reporter.
        currentTelegramMirrorEpoch = await renderCoordinator.advanceMirrorEpoch()
        await synchronizeTelegramTurnProgressReporting()
        await beginTelegramTurnPresenceIfNeeded()
        if let lease = origin.telegramLease, let eventQueue = telegramRuntimeEventQueue {
            let router = telegramSessionRouter
            telegramRouteValidationTask = Task(name: "ZenCODE.Telegram.route-validation") {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    guard (try? await router.validate(lease)) != nil else {
                        _ = await eventQueue.sendWithBackpressure(
                            .telegramRouteInvalidated(lease)
                        )
                        return
                    }
                }
            }
        }
    }

    /// Takes the lifecycle-safe typing lease for a mirrored turn. Presence is
    /// best-effort: a chat action that fails says nothing about the link or the
    /// turn, so failures are silent. The lease is released in
    /// `endTelegramTurnProgressReporting` and fenced by generation, so a
    /// renewal that wakes after teardown exits without touching the wire.
    private func beginTelegramTurnPresenceIfNeeded() async {
        guard let origin = activeTelegramTurnOrigin,
              await validateTelegramOrigin(origin),
              let chatID = telegramOutgoingChatID(for: origin),
              let fence = telegramWireFence(for: origin) else {
            return
        }
        activeTelegramPresenceLease = await telegramControlService.acquirePresenceLease(
            scope: .turn(
                chatID: chatID,
                topicID: origin.telegramLease?.effectiveMessageThreadID
            ),
            fence: fence
        )
    }

    /// Reconciles the current turn with the latest Telegram on/off state.
    /// Existing reporters are retained for the same chat so queued messages keep
    /// their ordering across a repeated `/telegram on`.
    ///
    /// Turning Telegram off drops the reporter together with the root response
    /// text it had aggregated; turning it back on starts a new, empty channel.
    /// A response block that was already streaming across such a transition is
    /// therefore suppressed, so the remote chat never receives a fragment whose
    /// beginning it could not see, nor a replay of text produced while off.
    func synchronizeTelegramTurnProgressReporting() async {
        guard let origin = activeTelegramTurnOrigin,
              let chatID = telegramOutgoingChatID(for: origin) else {
            if activeTelegramProgressReporter != nil {
                suppressTelegramRootResponseBlockIfStreaming()
            }
            let retired = activeTelegramProgressReporter
            if let retired { await retired.revokeAndWait() }
            activeTelegramProgressReporter = nil
            return
        }
        guard activeTelegramProgressReporter?.chatID != chatID else {
            return
        }
        suppressTelegramRootResponseBlockIfStreaming()
        activeTelegramProgressReporter = makeTelegramTurnProgressReporter(for: origin)
    }

    func endTelegramTurnProgressReporting() async {
        let validationTask = telegramRouteValidationTask
        telegramRouteValidationTask = nil
        validationTask?.cancel()
        await validationTask?.value
        let retiredReporter = activeTelegramProgressReporter
        if let retiredReporter { await retiredReporter.revokeAndWait() }
        if let lease = activeTelegramPresenceLease {
            await telegramControlService.releasePresenceLease(lease)
        }
        activeTelegramPresenceLease = nil
        activeTelegramProgressReporter = nil
        activeTelegramTurnOrigin = nil
        resetTelegramRootResponseBlock()
    }
}
