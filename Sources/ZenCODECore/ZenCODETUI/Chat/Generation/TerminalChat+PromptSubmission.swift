//
//  TerminalChat+PromptSubmission.swift
//  ZenCODE
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
        var lines = [
            "Type a prompt and press return."
        ]
        lines.append(contentsOf: visibleCommandDescriptorsForCurrentAgent().map(\.help))
        lines.append(contentsOf: [
            "Live chat: @coordinator <message>, @all <message>, or an @agent-name handle.",
            "Ctrl+G toggles default/full access for local.exec approvals in the interactive panel.",
            "Editing: Ctrl+A/Ctrl+E line start/end, Alt+</Alt+> draft start/end, "
                + "Alt+←/→ (or ESC b / ESC f) word motion.",
        ])
        return lines.joined(separator: "\n") + "\n\n"
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

        // A plain message is a clarification reply only while a Planner
        // explicitly has an unfinished question block.  This sits after live
        // mention routing and before slash processing so neither is absorbed.
        if Self.commandToken(from: prompt) == nil,
           let action = handlePlanBrainstormingReply(prompt) {
            return action
        }

        // Same rule for `/goal`: a plain message continues the open workflow
        // graph only while the coordinator is waiting for the user.
        if Self.commandToken(from: prompt) == nil,
           let action = await handleWorkflowContinuationReply(prompt) {
            return action
        }

        if case .slashCommand = Self.submittedLineRole(for: prompt) {
            if let unavailableMessage = unavailableLocalSlashCommandMessage(for: prompt) {
                await writeFailureMessage(unavailableMessage)
                return .continueChat
            }
            guard Self.isKnownSlashCommand(prompt) else {
                await writeFailureMessage(Self.unknownCommandMessage(for: prompt))
                return .continueChat
            }
        }

        switch prompt {
        case "/exit":
            return .exitChat
        case "/help":
            await writeSystemMessage(renderHelpTextForCurrentAgent())
            return .continueChat
        case "/setup":
            guard stdinIsTerminal else {
                await writeFailureMessage("ZenCODE: /setup requires an interactive terminal.\n")
                return .continueChat
            }
            return .requestSetup
        case let command where command.hasPrefix("/setup "):
            await writeFailureMessage("ZenCODE: /setup does not accept arguments.\n")
            return .continueChat
        case "/models":
            do {
                try await selectModelInteractively()
            } catch {
                await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            }
            return .continueChat
        case "/think":
            do {
                try await selectThinkingInteractively()
            } catch {
                await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            }
            return .continueChat
        case let command where command.hasPrefix("/think "):
            await writeFailureMessage("ZenCODE: /think does not accept arguments. Use /think to choose a level.\n")
            return .continueChat
        case let command where command == "/agents" || command.hasPrefix("/agents "):
            do {
                try await handleAgentsCommand(command)
            } catch {
                await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            }
            return .continueChat
        case let command where command == "/tools" || command.hasPrefix("/tools "):
            await handleToolsCommand(command)
            return .continueChat
        case let command where command == "/feature" || command.hasPrefix("/feature "):
            guard AgentProfileStore.isBuilderAgent(selectedAgent) else {
                await writeFailureMessage(Self.renderFeatureCommandUnavailableForAgent())
                return .continueChat
            }
            switch await handleFeatureCommand(command) {
            case .none:
                return .continueChat
            case let .runPrompt(prompt):
                return .runPrompt(prompt)
            case let .prefillPrompt(prompt):
                return .prefillPrompt(prompt)
            }
        case let command where command == "/skills" || command.hasPrefix("/skills "):
            await handleSkillsCommand(command)
            return .continueChat
        case let command where command == "/sessions" || command.hasPrefix("/sessions ")
            || command == "/session" || command.hasPrefix("/session "):
            await handleSessionsCommand(command)
            return .continueChat
        case let command where command == "/attach" || command.hasPrefix("/attach "):
            do {
                try await handleAttachCommand(command)
            } catch {
                await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            }
            return .continueChat
                case let command where command == "/open" || command.hasPrefix("/open "):
            await handleOpenCommand(command)
            return .continueChat
        case let command where command == "/changes" || command.hasPrefix("/changes "):
            await handleChangesCommand(command)
            return .continueChat
        case "/undo":
            await handleUndoFileChangesCommand()
            return .continueChat
        case let command where command == "/tasks" || command.hasPrefix("/tasks "):
            await handleTasksCommand(command)
            return .continueChat
        case let command where command == "/plan" || command.hasPrefix("/plan "):
            return await handlePlanCommand(command)
        case let command where command == "/goal" || command.hasPrefix("/goal "):
            return await handleWorkflowCommand(command)
        case let command where command == "/review" || command.hasPrefix("/review "):
            return await handleReviewCommand(command)
        case let command where command == "/telegram" || command.hasPrefix("/telegram "):
            await handleTelegramCommand(command)
            return .continueChat
        default:
            if case .slashCommand = Self.submittedLineRole(for: prompt) {
                await writeFailureMessage(Self.unknownCommandMessage(for: prompt))
                return .continueChat
            }
            return .runPrompt(prompt)
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
