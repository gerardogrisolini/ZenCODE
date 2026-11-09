//
//  ZenWindowSteps.swift
//  ZenApp
//
//  The steps of a window that read and write the session host in one hop
//  on the chat actor, and what they run with and return.
//

import Foundation
import ToolCore
import ZenCODECore

// MARK: - Steps on the chat actor

/// What a turn runs with.
struct ZenTurnStart: Sendable {
    let prompt: String
    let purpose: ChatTurnPurpose
    /// The operator typed the prompt: it locks the response language, takes
    /// the staged attachments, and shows. A prompt a command built does none
    /// of these.
    let typedByOperator: Bool
    /// The stop of the line that runs the turn.
    let stop: ZenLineStop
}

/// How a `/telegram on` ended, read in the step that ran it.
struct ZenTelegramActivation: Sendable {
    /// Telegram drove the slot before the activation.
    let wasDriving: Bool
    /// Telegram drives the slot after it.
    let isDriving: Bool
    /// The failure row of an activation that threw; `nil` otherwise.
    let failureText: String?
}

/// How a `/telegram off` ended, read in the step that ran it.
struct ZenTelegramDeactivation: Sendable {
    /// The slot had a Telegram channel: a `/telegram on` created it.
    let hadChannel: Bool
    /// Telegram drives the slot after it.
    let isDriving: Bool
    /// The prompt of the turn from Telegram still running, which the window
    /// adopts; `nil` when none runs.
    let adoptedPromptID: UUID?
}

/// The window's steps that read and write the host in one hop.
@ChatSessionActor
enum ZenWindowSteps {
    struct Anchor: Sendable {
        let epoch: UInt64
        let sequence: Int
    }

    static func bind(
        hooks: ZenWindowHooks,
        presenter: ZenWindowPresenter,
        to sessionHost: ChatSessionHost,
        slotID: ChatSlotID
    ) {
        hooks.sessionHost = sessionHost
        hooks.slotID = slotID
        presenter.sessionHost = sessionHost
        presenter.slotID = slotID
    }

    static func setHandlers(
        presenter: ZenWindowPresenter,
        hooks: ZenWindowHooks,
        fileMutation: @escaping @Sendable () -> Void,
        statusFacts: @escaping @Sendable () -> Void,
        savedSessionLoadStep: @escaping @Sendable (ZenSavedSessionLoadStep) -> Void,
        voiceCommentary: @escaping @Sendable (String) -> Void
    ) {
        presenter.fileMutationHandler = fileMutation
        presenter.voiceCommentaryHandler = voiceCommentary
        hooks.statusFactsHandler = statusFacts
        hooks.savedSessionLoadStepHandler = savedSessionLoadStep
    }

    /// The last log entry of the current reducer, for a local row.
    static func anchor(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> Anchor? {
        guard let snapshot = sessionHost.reducer(in: slotID)?.snapshot else { return nil }
        return Anchor(
            epoch: snapshot.epoch,
            sequence: ZenLocalTranscriptItem.anchorSequence(in: snapshot)
        )
    }

    /// Runs one turn of `controller` as one step: reserves the prompt, locks
    /// the response language for a prompt the operator typed, composes the
    /// configuration, then, only while the reservation still holds, the line
    /// is not stopped (``ZenTurnStart/stop``), and its task is not cancelled,
    /// takes the staged attachments (typed prompts only), marks a prompt a
    /// command built as hidden, and runs the turn, with no suspension between
    /// the check and `runTurn(_:)`; the reservation is released after it. A
    /// stop that lands before the check, even before the reservation, leaves
    /// the turn unstarted, never unfenced.
    ///
    /// For voice mode the turn starts right before `runTurn(_:)` and ends
    /// right after it, with the final answer the presenter read
    /// (``ZenWindowPresenter/finalAnswer(of:purpose:)``), or none when it
    /// failed. Each of its requests asks for voice mode's instruction, which
    /// it gets only while the window is the one voice mode follows
    /// (``ZenWindowVoiceHost/turnInstruction()``).
    static func runTurn(
        _ start: ZenTurnStart,
        controller: ChatSessionController,
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        hooks: ZenWindowHooks,
        presenter: ZenWindowPresenter,
        voiceHost: ZenWindowVoiceHost,
        hiddenPrompts: ZenHiddenPromptMailbox,
        didReserve: (@Sendable () async -> Void)?
    ) async -> ZenTurnOutcome {
        let reservation: ChatPromptReservation
        do {
            reservation = try sessionHost.reservePrompt(in: slotID)
        } catch {
            return .refused(error)
        }
        // The command that built the turn ran on the controller the slot runs.
        guard sessionHost.withReservedIncarnation(reservation, { $0.controller === controller }) == true else {
            sessionHost.releasePrompt(reservation)
            return .refused(.noSession)
        }
        await didReserve?()
        if start.typedByOperator {
            hooks.lockResponseLanguageIfNeeded()
        }
        let configuration = await controller.turnSessionConfiguration(
            for: start.purpose,
            responseLanguageSection: hooks.responseLanguageSection()
        )
        // From here to `runTurn(_:)` nothing suspends.
        guard sessionHost.holdsPrompt(reservation), !start.stop.isRequested, !Task.isCancelled else {
            sessionHost.releasePrompt(reservation)
            return .cancelledBeforeStart
        }
        let attachments = start.typedByOperator ? controller.consumePendingAttachments() : []
        if !start.typedByOperator, let snapshot = sessionHost.reducer(in: slotID)?.snapshot {
            hiddenPrompts.post(ZenHiddenPromptMailbox.Mark(
                epoch: snapshot.epoch,
                afterSequence: ZenLocalTranscriptItem.anchorSequence(in: snapshot)
            ))
        }
        let outcome: ZenTurnOutcome
        var finalAnswer: String?
        voiceHost.post(.turnStarted(host: voiceHost))
        do {
            let result = try await controller.runTurn(ChatTurnRequest(
                prompt: start.prompt,
                attachments: attachments,
                purpose: start.purpose,
                sessionConfiguration: configuration,
                // Asked for every request, so `/voice pause`, `/voice off`,
                // and a switch to another window apply from the next one.
                turnInstructionProvider: { @ChatSessionActor [weak voiceHost] in
                    await voiceHost?.turnInstruction()
                },
                origin: .app
            ))
            finalAnswer = presenter.finalAnswer(of: result, purpose: start.purpose)
            outcome = .finished
        } catch {
            outcome = .failed(error)
        }
        voiceHost.post(.turnEnded(finalAnswer: finalAnswer, host: voiceHost))
        sessionHost.releasePrompt(reservation)
        return outcome
    }

    /// Presents the closing notices of an operation on the current reducer.
    static func present(
        _ notices: [ChatSessionNotice],
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID
    ) async {
        guard !notices.isEmpty, let reducer = sessionHost.reducer(in: slotID) else { return }
        for notice in notices {
            await reducer.presentSessionNotice(notice)
        }
    }

    /// The graphs `/tasks` published that belong to the session the slot
    /// runs now, taken from `presenter` (those of an earlier session are
    /// dropped), with the last log entry of its reducer, for their cards;
    /// `nil` when there is none.
    static func requestedTaskGraphs(
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        presenter: ZenWindowPresenter
    ) -> RequestedTaskGraphs? {
        let published = presenter.takeExplicitTaskGraphs()
        guard !published.isEmpty, let anchor = anchor(in: sessionHost, slotID: slotID) else { return nil }
        let overviews = published.filter { $0.epoch == anchor.epoch }.map(\.overview)
        guard !overviews.isEmpty else { return nil }
        return RequestedTaskGraphs(anchor: anchor, overviews: overviews)
    }

    struct RequestedTaskGraphs: Sendable {
        let anchor: Anchor
        let overviews: [ChatTaskGraphOverview]
    }

    /// Cancels the prompt reserved on the slot, if one is; the id of the
    /// prompt it cancelled. Nothing is fenced when no prompt is reserved.
    static func cancelPrompt(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> UUID? {
        guard sessionHost.incarnation(in: slotID)?.activePromptID != nil else { return nil }
        return sessionHost.cancelPrompt(in: slotID)
    }

    /// The stop of a window: in one step, cancels the prompt reserved on the
    /// slot and refuses the open requests of the session it runs now; then,
    /// when the cancelled prompt is a turn of the slot's Telegram channel (one
    /// the window adopted at `/telegram off`), the channel stops it (nothing
    /// happens for the window's own prompts). `true` when it cancelled a
    /// prompt. While Telegram drives the slot it does nothing and returns
    /// `false`: a dormant window stops no turn the chat runs, as the
    /// terminal's Esc does not.
    static func stop(in sessionHost: ChatSessionHost, slotID: ChatSlotID) async -> Bool {
        guard sessionHost.activeChannel(in: slotID) == .primary else { return false }
        let cancelled = cancelPrompt(in: sessionHost, slotID: slotID)
        sessionHost.incarnation(in: slotID)?.pendingRequestHost?.cancelPendingRequests()
        guard let cancelled else { return false }
        await sessionHost.stopTelegramTurnIfReserved(cancelled, in: slotID)
        return true
    }

    /// Answers the request `id` of the session the slot runs now.
    static func answer(
        _ id: UUID,
        with answer: ChatPendingRequest.Answer?,
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID
    ) {
        _ = sessionHost.incarnation(in: slotID)?.pendingRequestHost?.resolve(id, answer: answer)
    }

    /// `/telegram on`: the slot's Telegram channel, created now when the slot
    /// has none, receives the window's notice sink once (the channel lives as
    /// long as the slot, across its sessions), before its first attach; then
    /// the slot is handed to Telegram, the window named `app` in the texts
    /// sent to the chat. The sink awaits `notice` (`isFailure` for the
    /// failure channel; the system and Markdown channels are message rows),
    /// so each notice lands before what the window writes after the
    /// activation.
    static func activateTelegram(
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        notice: @escaping @Sendable (_ text: String, _ isFailure: Bool) async -> Void
    ) async -> ZenTelegramActivation {
        if let channel = sessionHost.telegramChannelCreatingIfNeeded(in: slotID, primaryChannelDescription: "app"),
           channel.noticeSink == nil {
            channel.noticeSink = { text, noticeChannel in
                await notice(text, noticeChannel == .failure)
            }
        }
        let wasDriving = sessionHost.activeChannel(in: slotID) == .telegram
        var failureText: String?
        do {
            try await sessionHost.activateTelegram(in: slotID, primaryChannelDescription: "app")
        } catch let error as TelegramChannelAttachError {
            failureText = ZenWindowSession.withoutTrailingNewlines(error.failureText)
        } catch let error as ChatSessionHostError {
            failureText = ZenWindowSession.text(for: error)
        } catch {
            failureText = "ZenCODE: \(error.localizedDescription)"
        }
        return ZenTelegramActivation(
            wasDriving: wasDriving,
            isDriving: sessionHost.activeChannel(in: slotID) == .telegram,
            failureText: failureText
        )
    }

    /// `/telegram off`: without a Telegram channel nothing happens; otherwise
    /// the slot is taken back with no catch-up, and the channel's detach
    /// presents the stop text through its sink. The prompt reserved while
    /// Telegram drove the slot is a turn from Telegram (the dormant window
    /// reserves none): when it is still reserved afterwards, the window adopts
    /// it. Before the slot comes back, `presenter` starts that turn afresh,
    /// so what the turn presents to the window from then on is its own.
    static func deactivateTelegram(
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        presenter: ZenWindowPresenter
    ) async -> ZenTelegramDeactivation {
        guard sessionHost.telegramChannel(in: slotID) != nil else {
            return ZenTelegramDeactivation(
                hadChannel: false,
                isDriving: sessionHost.activeChannel(in: slotID) == .telegram,
                adoptedPromptID: nil
            )
        }
        let wasDriving = sessionHost.activeChannel(in: slotID) == .telegram
        let promptID = wasDriving ? sessionHost.incarnation(in: slotID)?.activePromptID : nil
        if promptID != nil {
            presenter.beginAdoptedTurn()
        }
        _ = await sessionHost.deactivateTelegram(in: slotID)
        var adoptedPromptID: UUID?
        if let promptID, isReserved(promptID, in: sessionHost, slotID: slotID) {
            adoptedPromptID = promptID
        }
        return ZenTelegramDeactivation(
            hadChannel: true,
            isDriving: sessionHost.activeChannel(in: slotID) == .telegram,
            adoptedPromptID: adoptedPromptID
        )
    }

    /// Whether `promptID` is still the prompt reserved on the session the
    /// slot runs now: `false` once it was released or cancelled, in another
    /// session (a prompt id belongs to one incarnation), and once the slot
    /// closed.
    static func isReserved(_ promptID: UUID, in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> Bool {
        sessionHost.incarnation(in: slotID)?.activePromptID == promptID
    }

    /// The final answer of the turn adopted from Telegram, which the
    /// presenter read once the turn presented it to the window; `nil` when
    /// it presented none (it failed, was stopped, or ended before the slot
    /// came back).
    static func takeAdoptedFinalAnswer(from presenter: ZenWindowPresenter) -> String? {
        presenter.takeAdoptedFinalAnswer()
    }

    /// Telegram drives the slot.
    static func isDrivenFromTelegram(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> Bool {
        sessionHost.activeChannel(in: slotID) == .telegram
    }

    /// The close of a window: closing the slot fences the turn that runs,
    /// drops its reservation, and refuses the open requests in one step,
    /// before it suspends; then the task-graph observer of the session the
    /// slot ran is stopped.
    static func close(_ sessionHost: ChatSessionHost, slotID: ChatSlotID) async {
        let controller = sessionHost.incarnation(in: slotID)?.controller
        await sessionHost.closeSlot(slotID)
        await controller?.stopTaskGraphObserver()
    }

    /// The shutdown of the runtime: one `shutdown()` of the host ends every
    /// slot, then the observers of the sessions they ran are stopped.
    static func shutdown(_ sessionHost: ChatSessionHost, slotIDs: [ChatSlotID]) async {
        let controllers = slotIDs.compactMap { sessionHost.incarnation(in: $0)?.controller }
        await sessionHost.shutdown()
        for controller in controllers {
            await controller.stopTaskGraphObserver()
        }
    }
}
