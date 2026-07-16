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

extension TerminalChat {
    func renderHelpTextForCurrentAgent() -> String {
        var lines = [
            "Type a prompt and press return."
        ]
        lines.append(contentsOf: visibleCommandDescriptorsForCurrentAgent().map(\.help))
        lines.append(contentsOf: [
            "Ctrl+T toggles compact/full tool output.",
            "Ctrl+A toggles default/full access for local.exec approvals in the interactive panel.",
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
            return await submittedTelegramLineAction(prompt)
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
        case let command where command == "/make-agents" || command.hasPrefix("/make-agents "):
            return await handleMakeAgentsCommand(command)
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
        case let command where command == "/workflow" || command.hasPrefix("/workflow "):
            return await handleWorkflowCommand(command)
        case let command where command == "/review" || command.hasPrefix("/review "):
            return await handleReviewCommand(command)
        case let command where command == "/telegram" || command.hasPrefix("/telegram "):
            await handleTelegramCommand(command)
            return .continueChat
        case let command where command == "/voice" || command.hasPrefix("/voice "):
            await handleVoiceCommand(command)
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
        TerminalPromptAttempt(
            prompt: prompt,
            attachments: origin == .local && isUserVisible ? consumePendingAttachmentsForPrompt() : [],
            origin: origin,
            locksResponseLanguage: isUserVisible,
            purpose: purpose
        )
    }

    func runPromptBlocking(_ attempt: TerminalPromptAttempt) async {
        do {
            didReceiveMetricsForCurrentPrompt = false
            didRefreshGitStatusDuringCurrentPrompt = false
            await statusBar.beginRequest()
            await statusBar.setProcessing(true)
            defer {
                await statusBar.setProcessing(false)
            }
            let promptTask = Task {
                try await generateResponse(attempt: attempt)
            }
            let stopMonitor = TerminalEscapeStopMonitor.startIfNeeded(
                isEnabled: stdinIsTerminal
            ) {
                promptTask.cancel()
            }
            let success: TerminalChatGenerationSuccess
            do {
                success = try await promptTask.value
            } catch {
                if let stopMonitor {
                    stopMonitor.cancel()
                    await stopMonitor.value
                }
                throw error
            }
            if let stopMonitor {
                stopMonitor.cancel()
                await stopMonitor.value
            }
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
    }
}
