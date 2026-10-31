//
//  TerminalChat+PromptSubmission.swift
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
import Synchronization

private struct TerminalPromptExecutionTasks {
    var promptTask: Task<TerminalChatGenerationSuccess, Error>?
    var stopMonitor: Task<Void, Never>?

    mutating func cancel() {
        promptTask?.cancel()
        stopMonitor?.cancel()
    }
}

extension TerminalChat {
    func renderHelpTextForCurrentAgent() -> String {
        ChatSessionNoticeText.text(
            for: .help(commandHelp: Self.commandRegistry.helpLines(in: currentCommandContext()))
        )
    }

    func commandSuggestionsForCurrentAgent() -> [TerminalCommandSuggestion] {
        visibleCommandDescriptorsForCurrentAgent().map { descriptor in
            TerminalCommandSuggestion(
                command: descriptor.command,
                summary: descriptor.summary,
                requiresArgument: descriptor.requiresArgument
            )
        }
    }

    func submittedLineAction(
        _ promptInput: String,
        origin: TerminalPromptOrigin = .local
    ) async -> TerminalSubmittedLineAction {
        let prompt = promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            if origin == .local && !pendingAttachments.isEmpty {
                return .runPrompt("")
            }
            return .continueChat
        }

        if origin != .local {
            return await submittedTelegramLineAction(
                prompt,
                origin: origin
            )
        }

        switch Self.parseSharedChatMention(
            from: prompt,
            readableHandles: await sessionRunner.sharedChatMentionHandles(rootSessionID: sessionID)
        ) {
        case let .route(sharedChatRoute):
            await sendSharedChatMention(sharedChatRoute)
            return .continueChat
        case .missingText:
            await writeFailureMessage(
                "ZenCODE message: add a message after the live mention.\n"
            )
            return .continueChat
        case .none:
            break
        }

        // A plain message answers the conversation that explicitly waits for
        // the operator (the Goal of `/plan approve`, a Planner question, a
        // `/goal` workflow question). It sits after live mention routing and
        // before slash processing, so neither is ever absorbed as a reply.
        if Self.commandToken(from: prompt) == nil,
           let outcome = await chatSession.pendingReplyAction(for: prompt) {
            return await terminalAction(presenting: outcome)
        }

        guard case .slashCommand = Self.submittedLineRole(for: prompt) else {
            return .runPrompt(prompt)
        }
        let outcome = await chatSession.handleCommandLine(
            prompt,
            context: currentCommandContext()
        )
        guard case .channelCommand = outcome.action else {
            return await terminalAction(presenting: outcome)
        }
        return await channelCommandAction(prompt)
    }

    /// The commands only the terminal runs (`/exit`, `/setup`, `/feature`,
    /// `/tools logs`, `/telegram`, `/cron`, `/voice`, `/ds4`), once the
    /// shared dispatcher resolved them as visible channel commands.
    private func channelCommandAction(_ command: String) async -> TerminalSubmittedLineAction {
        switch command {
        case "/exit":
            return .exitChat
        case "/setup":
            guard stdinIsTerminal else {
                await writeFailureMessage("ZenCODE: /setup requires an interactive terminal.\n")
                return .continueChat
            }
            return .requestSetup
        case let command where command.hasPrefix("/setup "):
            await writeFailureMessage("ZenCODE: /setup does not accept arguments.\n")
            return .continueChat
        case let command where command == "/tools" || command.hasPrefix("/tools "):
            await handleToolsCommand(command)
            return .continueChat
        case let command where command == "/feature" || command.hasPrefix("/feature "):
            switch await handleFeatureCommand(command) {
            case .none:
                return .continueChat
            case let .runPrompt(prompt):
                return .runPrompt(prompt)
            case let .prefillPrompt(prompt):
                return .prefillPrompt(prompt)
            }
        case let command where command == "/telegram" || command.hasPrefix("/telegram "):
            await handleTelegramCommand(command)
            return .continueChat
        case let command where command == "/cron" || command.hasPrefix("/cron "):
            await handleCronCommand(command)
            return .continueChat
        case let command where command == "/voice" || command.hasPrefix("/voice "):
            await handleVoiceCommand(command)
            return .continueChat
        case let command where command == "/ds4" || command.hasPrefix("/ds4 "):
            await handleDS4Command(command)
            return .continueChat
        default:
            await writeFailureMessage(Self.unknownCommandMessage(for: command))
            return .continueChat
        }
    }

    func promptAttempt(
        prompt: String,
        origin: TerminalPromptOrigin = .local,
        isUserVisible: Bool = true,
        purpose: TerminalPromptPurpose = .normal
    ) -> TerminalPromptAttempt {
        // `/telegram on` mirrors terminal-originated turns through the currently
        // validated route lease. Keep attachment ownership based on the original
        // local origin: promoting the routing origin must not leave locally
        // selected attachments pending for the following prompt.
        let routedOrigin: TerminalPromptOrigin
        if origin == .local,
           telegramControlState.isActive,
           let lease = telegramActiveRouteLease {
            routedOrigin = .telegramLease(lease)
        } else {
            routedOrigin = origin
        }
        return TerminalPromptAttempt(
            prompt: prompt,
            attachments: origin == .local && isUserVisible ? consumePendingAttachmentsForPrompt() : [],
            origin: routedOrigin,
            locksResponseLanguage: isUserVisible,
            purpose: purpose
        )
    }

    func runPromptBlocking(_ attempt: TerminalPromptAttempt) async {
        do {
            // The blocking loop also accepts hidden shared-chat and planner
            // turns, which bypass `writeSubmittedPrompt`. Reopen the terminal
            // overview gate at every generation entry, matching the interactive
            // loop without replaying the preceding turn's withheld summaries.
            await renderCoordinator.beginTranscriptTurn()
            didRefreshGitStatusDuringCurrentPrompt = false
            await statusBar.beginRequest()
            await statusBar.setProcessing(true)
            let tasks = Mutex(TerminalPromptExecutionTasks())
            let success = try await withTaskCancellationHandler(
                operation: {
                    let promptTask = Task(name: "ZenCODE.TUI.prompt-generation") {
                        try await self.generateResponse(attempt: attempt)
                    }
                    tasks.withLock { tasks in
                        tasks.promptTask = promptTask
                    }

                    let turnSessionID = self.sessionID
                    let sessionRunner = self.sessionRunner
                    let stopMonitor = TerminalEscapeStopMonitor.startIfNeeded(
                        isEnabled: self.stdinIsTerminal
                    ) {
                        promptTask.cancel()
                        await sessionRunner.cancelPrompt(sessionID: turnSessionID)
                    }
                    tasks.withLock { tasks in
                        tasks.stopMonitor = stopMonitor
                    }
                    // Cancellation may have raced with task creation, before
                    // `onCancel` could observe both children. Re-check after
                    // publishing them so neither child outlives this attempt.
                    if Task.isCancelled {
                        tasks.withLock { tasks in
                            tasks.cancel()
                        }
                    }

                    do {
                        let success = try await promptTask.value
                        if let stopMonitor = tasks.withLock({ tasks -> Task<Void, Never>? in
                            let stopMonitor = tasks.stopMonitor
                            tasks.stopMonitor = nil
                            return stopMonitor
                        }) {
                            stopMonitor.cancel()
                            await stopMonitor.value
                        }
                        return success
                    } catch {
                        if let stopMonitor = tasks.withLock({ tasks -> Task<Void, Never>? in
                            let stopMonitor = tasks.stopMonitor
                            tasks.stopMonitor = nil
                            return stopMonitor
                        }) {
                            stopMonitor.cancel()
                            await stopMonitor.value
                        }
                        throw error
                    }
                },
                onCancel: {
                    tasks.withLock { tasks in
                        tasks.cancel()
                    }
                }
            )
            await finishPromptResult(.success(success))
            await refreshStatusBarGitStatusSummaryAfterPromptIfNeeded()
        } catch {
            let failure = TerminalChatGenerationFailure(
                error: error,
                origin: attempt.origin
            )
            await finishPromptResult(.failure(failure))
            await refreshStatusBarGitStatusSummaryAfterPromptIfNeeded()
        }
        await statusBar.setProcessing(false)
    }
}
