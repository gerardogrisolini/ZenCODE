//
//  TerminalChat+InputLoop+Blocking.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Serializes ordinary and shared-chat-generated turns in the blocking input
/// fallback. Unlike the interactive panel, that loop has no event queue whose
/// `isGenerating` state can provide the same exclusion.
private actor TerminalBlockingPromptGate {
    private var isHeld = false
    private var waiters: [(
        id: UUID,
        continuation: CheckedContinuation<Bool, Never>
    )] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isHeld else {
            isHeld = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((waiterID, continuation))
            }
        } onCancel: {
            Task(name: "ZenCODE.TUI.blocking-prompt-gate-cancel") {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

extension TerminalChat {
    static func readConsentKeyOffActor(
        reader: TerminalInteractiveLineReader,
        prompt: String
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            reader.readSingleKey(
                prompt: prompt,
                shouldCancel: token.isCancelled
            )
        }
    }

    /// Reads one interactive line off the cooperative executor.
    ///
    /// `readLine(prompt:)` puts the terminal in raw mode and blocks the thread
    /// until a line is submitted, so it must never run on `TerminalChatActor`
    /// (it would stall rendering, the status bar and background refreshes). The
    /// read is cancellation-aware, so a cancelled turn never leaves the terminal
    /// owned by a read nobody awaits.
    static func readLineOffActor(
        reader: TerminalInteractiveLineReader,
        prompt: String
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            reader.readLine(prompt: prompt, shouldCancel: token.isCancelled)
        }
    }

    /// Reads a single piped line off the cooperative executor.
    ///
    /// Used for the first non-interactive line, before the input loop takes over;
    /// no paste drain happens because the line becomes the loop's pending input.
    /// The bridge token is passed down so the poll unwinds on cancellation: the
    /// bridge waits for this body, so ignoring it would hold teardown.
    static func readStdinLineOffActor(
        reader: StdioLineReader
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            reader.readLine(shouldCancel: token.isCancelled)
        }
    }

    /// Reads one piped line plus any buffered paste continuation off the
    /// cooperative executor. Both calls block on stdin, so they run together to
    /// keep the paste-drain window contiguous with its originating line. The
    /// token covers *both* halves: against a continuous producer the drain has
    /// no natural end, so only cancellation ends it.
    static func readPipedLineOffActor(
        reader: StdioLineReader,
        initialLine: String?,
        waitMilliseconds: Int32
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            guard let line = initialLine
                ?? reader.readLine(shouldCancel: token.isCancelled) else {
                return nil
            }
            guard !token.isCancelled() else {
                return nil
            }
            let pastedLines = reader.drainBufferedLines(
                waitMilliseconds: waitMilliseconds,
                shouldCancel: token.isCancelled
            )
            return ([line] + pastedLines).joined(separator: "\n")
        }
    }

    /// Handles one shared-chat event for the blocking input fallback.
    ///
    /// Keeping this out of the stream pump leaves the supervisor responsible for
    /// stream lifecycle only, while room binding, trigger claiming and turn
    /// serialization stay here, unchanged.
    private func handleBlockingSharedChatEvent(
        _ event: AgentSharedChatCoordinatorEvent,
        observation: AgentSharedChatCoordinator.Observation,
        promptGate: TerminalBlockingPromptGate
    ) async {
        switch event {
        case let .messages(messages):
            // Shared-chat traffic is never appended to the main transcript.
            // `/telegram` works in this fallback too, so cards are forwarded;
            // the relay binding is refreshed at the room boundary, and this
            // guard only drops batches of a room that is no longer live.
            guard observation.roomID == sessionID else { break }
            await forwardSharedChatMessagesToTelegram(
                messages,
                roomID: observation.roomID
            )
        case .participantsChanged:
            break
        case let .autoTrigger(trigger):
            guard trigger.roomID == sessionID,
                  trigger.roomID == observation.roomID else {
                await sessionRunner.declineSharedChatAutoTrigger(
                    id: trigger.id,
                    rootSessionID: trigger.roomID
                )
                return
            }
            let claim = await sessionRunner.resolveSharedChatAutoTrigger(
                id: trigger.id,
                observation: observation,
                resolution: .started
            )
            guard claim == .acquired else { return }

            guard await promptGate.acquire() else { return }
            // Session replacement can race while this trigger waits
            // behind an ordinary turn. The claimed batch is returned
            // by detach below rather than sent into the new session.
            guard trigger.roomID == sessionID else {
                await promptGate.release()
                return
            }
            await runPromptBlocking(
                promptAttempt(
                    prompt: trigger.prompt,
                    origin: takeTelegramSharedChatOrigin(for: trigger.messages) ?? .local,
                    isUserVisible: false
                )
            )
            await promptGate.release()
        }
    }

    func runBlockingInputLoop(initialInputLine: String?) async throws {
        var pendingInputLine = initialInputLine
        let promptGate = TerminalBlockingPromptGate()
        // This loop is parked inside `readLine` for an unbounded time, so the
        // observation lifecycle cannot depend on it: the supervisor re-attaches
        // from the producer path as soon as a stream ends without cancellation.
        let sharedChatObservations = TerminalSharedChatObservationSupervisor(
            roomID: sessionID,
            environment: TerminalSharedChatObservationSupervisor.Environment(
                attach: { [sessionRunner] roomID in
                    await sessionRunner.attachSharedChatObservation(
                        rootSessionID: roomID
                    )
                },
                detach: { [sessionRunner] observation in
                    await sessionRunner.detachSharedChatObservation(observation)
                },
                handleEvent: { [weak self] event, observation in
                    await self?.handleBlockingSharedChatEvent(
                        event,
                        observation: observation,
                        promptGate: promptGate
                    )
                }
            )
        )
        await sharedChatObservations.start()
        // Bind the relay to the initial room up front. Waiting for the first
        // `.messages` batch would leave a `/telegram on` session unbound in a
        // quiet room, so nothing addressed to the operator would be forwarded.
        await rebindTelegramSharedChatRelay(roomID: sessionID)

        var shouldContinue = true
        while shouldContinue {
            let promptInput: String
            if stdinIsTerminal {
                guard let line = await Self.readLineOffActor(
                    reader: interactiveReader,
                    prompt: "> "
                ) else {
                    break
                }
                promptInput = line
            } else {
                guard let line = await Self.readPipedLineOffActor(
                    reader: reader,
                    initialLine: pendingInputLine,
                    waitMilliseconds: 80
                ) else {
                    break
                }
                pendingInputLine = nil
                promptInput = line
            }

            switch await submittedLineAction(promptInput) {
            case .continueChat:
                break
            case .exitChat:
                shouldContinue = false
            case .requestSetup:
                requestedRuntimeSetup = true
                shouldContinue = false
            case let .runPrompt(prompt):
                guard await promptGate.acquire() else {
                    shouldContinue = false
                    break
                }
                await runPromptBlocking(promptAttempt(prompt: prompt))
                await promptGate.release()
            case let .runHiddenPrompt(prompt, purpose):
                guard await promptGate.acquire() else {
                    shouldContinue = false
                    break
                }
                await runPromptBlocking(
                    promptAttempt(prompt: prompt, isUserVisible: false, purpose: purpose)
                )
                await promptGate.release()
            case let .prefillPrompt(prompt):
                await writeSystemMessage("Draft prompt:\n\(prompt)\n")
            }

            if shouldContinue {
                // Fence and bind Telegram before attaching the next room's
                // observer. Its replay may arrive as soon as `follow` suspends;
                // binding afterward could drop that first batch or let a retired
                // room keep sending during the attach. Re-activating an
                // unchanged room is idempotent.
                await rebindTelegramSharedChatRelay(roomID: sessionID)
                // A stream that ended by itself was already repaired; this only
                // follows a `/new` or `/resume` room swap.
                await sharedChatObservations.follow(roomID: sessionID)
            }
        }

        await sharedChatObservations.stop()
    }
}
