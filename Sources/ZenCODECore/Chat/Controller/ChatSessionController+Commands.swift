//
//  ChatSessionController+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// What `/sessions` does, read from its arguments
/// (``ChatSessionController/savedSessionCommandAction(rawArguments:)``).
enum ChatSavedSessionCommandAction: Equatable, Sendable {
    /// `/sessions`: list and pick a saved session.
    case list
    /// `/sessions delete`.
    case delete
    /// `/sessions new`.
    case newSession
    /// `/sessions save`.
    case saveActive
    /// `/sessions compact`.
    case compact
    /// `/sessions memory`.
    case memory
    /// `/sessions restore [entry-id]`; an empty ID asks with a picker.
    case restore(entryID: String)
    /// `/sessions <name>`.
    case saveNamed(String)
}

/// The shared dispatcher of slash commands.
///
/// ``handleCommandLine(_:context:)`` resolves the command a line names in
/// ``commandRegistry`` and runs it: the shared commands here, on the
/// operations of the controller, and every command only the channel runs as
/// ``ChatCommandAction/channelCommand``, for the channel to run. A line that
/// names no command, or a command the operator does not see, is answered
/// here.
///
/// Each shared command takes the line the terminal handed its handler, with
/// the arguments read the same way, and answers in the terminal's order: the
/// steps the terminal ran between an operation and its closing notices run
/// through the ``ChatSessionChannelHooks`` command hooks, and the closing
/// notices are the outcome's. A failure the terminal wrote as
/// `ZenCODE: <error>` is ``ChatSessionNotice/operationFailed(description:)``.
extension ChatSessionController {
    // MARK: - Dispatcher

    /// Runs the slash command `line` names, for an operator who sees the
    /// commands `context` allows.
    public func handleCommandLine(
        _ line: String,
        context: ChatCommandContext
    ) async -> ChatCommandOutcome {
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let descriptor = commandRegistry.descriptor(forLine: command) else {
            return ChatCommandOutcome(notices: [.unknownCommand(line: command)])
        }
        if let message = commandRegistry.message(
            forHiddenLine: command,
            context: context,
            isGenerating: false
        ) {
            return ChatCommandOutcome(notices: [
                descriptor.hiddenMessage == nil
                    ? .unknownCommand(line: command)
                    : .commandUnavailable(message: message),
            ])
        }
        guard descriptor.scope == .shared else {
            return ChatCommandOutcome(action: .channelCommand)
        }

        switch descriptor.command {
        case "/help":
            // `/help` takes no arguments: with some, the line names no command.
            guard Self.commandArguments(of: command).isEmpty else {
                return ChatCommandOutcome(notices: [.unknownCommand(line: command)])
            }
            return ChatCommandOutcome(notices: [
                .help(commandHelp: commandRegistry.helpLines(in: context)),
            ])
        case "/models":
            return await runModelsCommand(line: command)
        case "/think":
            return await runThinkCommand(line: command)
        case "/agents":
            return await runAgentsCommand(line: command)
        case "/tools":
            return await runToolsCommand(line: command)
        case "/skills":
            return await runSkillsCommand(line: command)
        case "/sessions":
            return await runSessionsCommand(line: command)
        case "/attach":
            return await runAttachCommand(line: command)
        case "/open":
            return await runOpenCommand(line: command)
        case "/artifacts":
            return await runArtifactsCommand(line: command)
        case "/changes":
            return await runChangesCommand(line: command)
        case "/undo":
            return await runUndoCommand(line: command)
        case "/tasks":
            return await runTasksCommand(line: command)
        case "/plan":
            return await runPlanCommand(line: command)
        case "/goal":
            return await runGoalCommand(line: command)
        case "/review":
            return await runReviewCommand(line: command)
        default:
            return ChatCommandOutcome(notices: [.unknownCommand(line: command)])
        }
    }

    /// What follows the command token of `line`, trimmed.
    private static func commandArguments(of line: String) -> String {
        guard let token = ChatCommandRegistry.commandToken(from: line) else {
            return ""
        }
        return ChatCommandRegistry.arguments(from: line, commandPrefix: token)
    }

    /// The closing notices of a selection command, after the channel's step
    /// for the selection it applied.
    private func selectionCommandOutcome(
        _ outcome: ChatSelectionOutcome,
        command: ChatSelectionCommand
    ) async -> ChatCommandOutcome {
        if let change = outcome.change {
            await channelHooks?.selectionDidApply(change, command: command)
        }
        return ChatCommandOutcome(notices: outcome.notices)
    }

    /// A failure the terminal wrote as `ZenCODE: <error>`.
    private static func failedCommand(_ error: Error) -> ChatCommandOutcome {
        ChatCommandOutcome(notices: [.operationFailed(description: error.localizedDescription)])
    }

    // MARK: - /models and /think

    /// `/models`: the model menu (``chooseModel()``). It takes no arguments.
    func runModelsCommand(line: String = "/models") async -> ChatCommandOutcome {
        guard Self.commandArguments(of: line).isEmpty else {
            return ChatCommandOutcome(notices: [.unknownCommand(line: line)])
        }
        do {
            return await selectionCommandOutcome(try await chooseModel(), command: .models)
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// `/think`: the thinking menu (``chooseThinking()``). Arguments are
    /// refused: the level is chosen from the menu.
    func runThinkCommand(line: String = "/think") async -> ChatCommandOutcome {
        guard Self.commandArguments(of: line).isEmpty else {
            return ChatCommandOutcome(notices: [.thinkingTakesNoArguments])
        }
        do {
            return await selectionCommandOutcome(try await chooseThinking(), command: .thinking)
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// The model `modelID` a channel picked from a model menu it presents
    /// itself (``modelChoices()``), applied as a confirmed `/models` menu:
    /// ``selectModel(id:)``, then the channel's step for the selection.
    public func applyModelSelection(id modelID: String) async -> ChatCommandOutcome {
        do {
            return await selectionCommandOutcome(
                try await selectModel(id: modelID),
                command: .models
            )
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// The thinking level `thinkingID` a channel picked from a thinking menu
    /// it presents itself (``thinkingMenu()``), applied as a confirmed
    /// `/think` menu: ``selectThinking(_:)``, then the channel's step for the
    /// selection. The level must be one of the current model's options
    /// (otherwise ``ChatSelectionError/unknownThinkingLevel(_:)``); without a
    /// configurable current model the notice `/think` answers with is the
    /// answer.
    public func applyThinkingSelection(id thinkingID: String) async -> ChatCommandOutcome {
        do {
            switch try thinkingMenu() {
            case let .unavailable(notice):
                return ChatCommandOutcome(notices: [notice])
            case let .available(choices):
                guard choices.items.contains(where: { $0.id == thinkingID }),
                      let thinkingSelection = AgentThinkingSelection(rawValue: thinkingID) else {
                    throw ChatSelectionError.unknownThinkingLevel(thinkingID)
                }
                return await selectionCommandOutcome(
                    try await selectThinking(thinkingSelection),
                    command: .thinking
                )
            }
        } catch {
            return Self.failedCommand(error)
        }
    }

    // MARK: - /agents

    /// `/agents`: the project's agent menu without arguments
    /// (``chooseProjectAgents()``), the selected agent and the agent list for
    /// `list`, `ls`, or `status`, otherwise the agent the arguments name
    /// (``selectAgent(rawSelection:)``).
    func runAgentsCommand(line: String) async -> ChatCommandOutcome {
        let rawArguments = ChatCommandRegistry.arguments(from: line, commandPrefix: "/agents")
        do {
            if rawArguments.isEmpty {
                return await selectionCommandOutcome(
                    try await chooseProjectAgents(),
                    command: .agents
                )
            }
            switch rawArguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "list", "ls", "status":
                var notices: [ChatSessionNotice] = [.selectedAgent(selection.agent)]
                do {
                    notices.append(
                        .availableAgents(
                            agents: try availableAgents(),
                            selected: selection.agent,
                            manifestPath: AgentProfileStore.agentsManifestURL().path
                        )
                    )
                } catch {
                    notices.append(.operationFailed(description: error.localizedDescription))
                }
                return ChatCommandOutcome(notices: notices)
            default:
                return await selectionCommandOutcome(
                    try await selectAgent(rawSelection: rawArguments),
                    command: .agents
                )
            }
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// The agent `agentID` (``agentChoiceID(_:)``) a channel picked from an
    /// agent menu it presents itself (``agentChoices()``), activated as
    /// `/agents <agent>` activates it (``selectAgent(_:)``), then the
    /// channel's step for the selection. An ID of no available profile is
    /// ``TerminalAgentSelectionError/unknownAgent(_:)``.
    public func applyAgentSelection(id agentID: String) async -> ChatCommandOutcome {
        do {
            guard let agent = try availableAgents().first(where: {
                Self.agentChoiceID($0) == agentID
            }) else {
                throw TerminalAgentSelectionError.unknownAgent(agentID)
            }
            return await selectionCommandOutcome(try await selectAgent(agent), command: .agents)
        } catch {
            return Self.failedCommand(error)
        }
    }

    // MARK: - /tools

    /// `true` for the arguments of `/tools logs`, which only the channel runs.
    nonisolated static func isToolLogsRequest(_ rawArguments: String) -> Bool {
        let tokens = rawArguments.split(whereSeparator: \.isWhitespace)
        return tokens.count == 1 && tokens[0].lowercased() == "logs"
    }

    /// `/tools`: the tool menu without arguments (``chooseTools()``),
    /// otherwise the selection the arguments name. `/tools logs` is the
    /// channel's.
    func runToolsCommand(line: String) async -> ChatCommandOutcome {
        let rawArguments = ChatCommandRegistry.arguments(from: line, commandPrefix: "/tools")
        if Self.isToolLogsRequest(rawArguments) {
            return ChatCommandOutcome(action: .channelCommand)
        }
        if rawArguments.isEmpty {
            return await selectionCommandOutcome(await chooseTools(), command: .tools)
        }
        return await applyToolSelectionCommand(rawSelection: rawArguments)
    }

    /// The tool selection `rawSelection` names
    /// (``selectTools(rawSelection:)``); a selection that cannot be read is
    /// answered with the failure and the usage.
    func applyToolSelectionCommand(rawSelection: String) async -> ChatCommandOutcome {
        do {
            return await selectionCommandOutcome(
                try await selectTools(rawSelection: rawSelection),
                command: .tools
            )
        } catch {
            return ChatCommandOutcome(notices: [
                .operationFailed(description: error.localizedDescription),
                .toolSelectionUsage,
            ])
        }
    }

    /// The tool groups `keys` (``selectTools(keys:)``), as a channel applies
    /// them itself.
    func applyToolSelectionCommand(keys: Set<String>) async -> ChatCommandOutcome {
        await selectionCommandOutcome(await selectTools(keys: keys), command: .tools)
    }

    // MARK: - /skills

    /// `/skills`: the uninstall picker, an install from a GitHub URL or a
    /// local path, the skill menu without arguments, otherwise the selection
    /// the arguments name.
    func runSkillsCommand(line: String) async -> ChatCommandOutcome {
        let rawArguments = ChatCommandRegistry.arguments(from: line, commandPrefix: "/skills")

        if Self.isSkillUninstallRequest(rawArguments) {
            return await selectionCommandOutcome(await chooseSkillsToUninstall(), command: .skills)
        }

        let installValue = Self.skillInstallValue(from: rawArguments)
        if Self.isSkillInstallRequest(rawArguments)
            || installValue.flatMap({
                Self.skillInstallSource($0, workingDirectory: workingDirectory)
            }) != nil {
            return await selectionCommandOutcome(
                await installSkill(source: installValue ?? ""),
                command: .skills
            )
        }

        if rawArguments.isEmpty {
            return await selectionCommandOutcome(await chooseSkills(), command: .skills)
        }

        return await applySkillSelectionCommand(rawSelection: rawArguments)
    }

    /// The skill selection `rawSelection` names
    /// (``selectSkills(rawSelection:)``); a selection that cannot be read is
    /// answered with the failure and the usage.
    func applySkillSelectionCommand(rawSelection: String) async -> ChatCommandOutcome {
        do {
            return await selectionCommandOutcome(
                try await selectSkills(rawSelection: rawSelection),
                command: .skills
            )
        } catch {
            return ChatCommandOutcome(notices: [
                .operationFailed(description: error.localizedDescription),
                .skillSelectionUsage,
            ])
        }
    }

    /// The skills `names` (``selectSkills(names:)``), as a channel applies them
    /// itself.
    func applySkillSelectionCommand(names: Set<String>) async -> ChatCommandOutcome {
        await selectionCommandOutcome(await selectSkills(names: names), command: .skills)
    }

    /// Installs the skill at `source` (``installSkill(from:)``), as a channel
    /// installs it itself.
    func installSkillCommand(from source: SkillInstallSource) async -> ChatCommandOutcome {
        await selectionCommandOutcome(await installSkill(from: source), command: .skills)
    }

    // MARK: - /sessions

    /// What `/sessions` does with `rawArguments`: a keyword (`delete`, `new`,
    /// `save`, `compact`, `memory`, `restore [entry-id]`) in any case, nothing
    /// for the list, otherwise a name to save the session as.
    nonisolated static func savedSessionCommandAction(
        rawArguments: String
    ) -> ChatSavedSessionCommandAction {
        let trimmedArguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split into subcommand + remainder for keyword-based actions.
        let firstSpace = trimmedArguments.firstIndex(of: " ")
        let subcommand: String
        let remainder: String
        if let firstSpace {
            subcommand = String(trimmedArguments[..<firstSpace]).lowercased()
            remainder = String(trimmedArguments[trimmedArguments.index(after: firstSpace)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            subcommand = trimmedArguments.lowercased()
            remainder = ""
        }

        switch subcommand {
        case "":
            return .list
        case "delete":
            return .delete
        case "new":
            return .newSession
        case "save":
            return .saveActive
        case "compact":
            return .compact
        case "memory":
            return .memory
        case "restore":
            return .restore(entryID: remainder)
        default:
            return .saveNamed(trimmedArguments)
        }
    }

    /// `/sessions` and its actions. The arguments follow `/sessions`, so the
    /// `/session` alias always lists the saved sessions, as it always did.
    func runSessionsCommand(line: String) async -> ChatCommandOutcome {
        let rawArguments = ChatCommandRegistry.arguments(from: line, commandPrefix: "/sessions")
        switch Self.savedSessionCommandAction(rawArguments: rawArguments) {
        case .list:
            return await savedSessionListCommand()
        case .delete:
            return await savedSessionDeleteCommand()
        case .newSession:
            return await newSessionCommand()
        case .saveActive:
            return await saveActiveSessionCommand()
        case .compact:
            return await compactSessionCommand()
        case .memory:
            return await sessionMemoryCommand()
        case let .restore(entryID):
            return await restoreCheckpointCommand(entrySpecifier: entryID)
        case let .saveNamed(name):
            return await saveSessionCommand(named: name)
        }
    }

    /// `/sessions`: picks a saved session and loads it
    /// (``chooseSavedSession()``).
    func savedSessionListCommand() async -> ChatCommandOutcome {
        do {
            return ChatCommandOutcome(notices: try await chooseSavedSession().notices)
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// Loads the saved session `name` a channel picked from a saved-session
    /// menu it presents itself (``savedSessions()``), as a confirmed
    /// `/sessions` menu loads it (``loadSavedSession(_:checkpointEntryID:)``).
    /// A name of no saved session of the project is
    /// ``ChatSessionNotice/savedSessionNotFound(name:)``.
    public func loadSavedSessionSelection(named name: String) async -> ChatCommandOutcome {
        do {
            guard let session = try savedSessions().first(where: { $0.name == name }) else {
                return ChatCommandOutcome(notices: [.savedSessionNotFound(name: name)])
            }
            return ChatCommandOutcome(notices: try await loadSavedSession(session).notices)
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// `/sessions delete` (``chooseSavedSessionsToDelete()``).
    func savedSessionDeleteCommand() async -> ChatCommandOutcome {
        do {
            return ChatCommandOutcome(notices: try await chooseSavedSessionsToDelete().notices)
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// `/sessions new`: resets the runtime conversation and starts a fresh,
    /// unsaved session (``startNewSession(newSessionID:)``) with the ID the
    /// slot mints (``mintNewSessionID()``), between the channel's steps
    /// around a new session (``ChatIncarnationChange/newSessionWillStart``
    /// and ``ChatIncarnationChange/newSessionDidStart``).
    func newSessionCommand() async -> ChatCommandOutcome {
        do {
            await channelHooks?.incarnationDidChange(reason: .newSessionWillStart)
            let outcome = try await startNewSession(newSessionID: mintNewSessionID())
            await channelHooks?.incarnationDidChange(reason: .newSessionDidStart)
            return ChatCommandOutcome(notices: outcome.notices)
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// The ID of the session `/sessions new` starts: in a host's slot, the
    /// slot's prefix and a new UUID (``ChatSlotDescriptor/sessionIDPrefix``);
    /// otherwise ``mintedSessionID()``.
    func mintNewSessionID() -> String {
        if let binding = hostBinding, let host = binding.host,
           let sessionID = host.mintSessionID(in: binding.slotID) {
            return sessionID
        }
        return Self.mintedSessionID()
    }

    /// The ID of a new session outside a host's slot.
    nonisolated static func mintedSessionID() -> String {
        mintedSessionID(prefix: ChatSlotDescriptor.defaultSessionIDPrefix)
    }

    /// `prefix`, a dash, and a new lowercased UUID: the format of every
    /// session ID the controller and the host mint.
    nonisolated static func mintedSessionID(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }

    /// `/sessions save` (``saveActiveSession(contextWindow:)``), with the
    /// context window the channel shows.
    func saveActiveSessionCommand() async -> ChatCommandOutcome {
        let contextWindow = await channelHooks?.commandContextWindow() ?? nil
        return ChatCommandOutcome(
            notices: await saveActiveSession(contextWindow: contextWindow).notices
        )
    }

    /// `/sessions <name>` (``saveSession(named:contextWindow:)``), with the
    /// context window the channel shows.
    func saveSessionCommand(named rawName: String) async -> ChatCommandOutcome {
        let contextWindow = await channelHooks?.commandContextWindow() ?? nil
        return ChatCommandOutcome(
            notices: await saveSession(named: rawName, contextWindow: contextWindow).notices
        )
    }

    /// `/sessions compact` (``compactSession(maxTokensOverride:)``), bounded
    /// by the maximum of the context window the channel shows when it is
    /// positive; the channel shows the compacted window.
    func compactSessionCommand() async -> ChatCommandOutcome {
        do {
            let contextWindow = await channelHooks?.commandContextWindow() ?? nil
            let runtimeMaxTokens = contextWindow?.maxTokens
                .flatMap { $0 > 0 ? $0 : nil }
            let outcome = try await compactSession(maxTokensOverride: runtimeMaxTokens)
            if let compactedWindow = outcome.contextWindow {
                await channelHooks?.incarnationDidChange(
                    reason: .sessionDidCompact(contextWindow: compactedWindow)
                )
            }
            return ChatCommandOutcome(notices: [outcome.notice])
        } catch {
            return Self.failedCommand(error)
        }
    }

    /// `/sessions memory`: the project-memory block the last prompt of the
    /// session was sent with, taken as it was stored with the prompt
    /// (``AgentRuntimeMessage/turnAddition``); nothing is recalled again. A
    /// session with no prompt yet, a last prompt sent without a block, or no
    /// snapshot of the session is ``ChatSessionNotice/noTurnMemoryBlock``.
    func sessionMemoryCommand() async -> ChatCommandOutcome {
        let snapshot = await runtime.snapshotSession(id: sessionID)
        let lastPrompt = snapshot?.history.last { $0.role == .user }
        guard let block = MemoryTurnCoordinator.memoryBlock(
            inTurnAddition: lastPrompt?.turnAddition
        ) else {
            return ChatCommandOutcome(notices: [.noTurnMemoryBlock])
        }
        return ChatCommandOutcome(notices: [.turnMemoryBlock(block)])
    }

    /// `/sessions restore [entry-id]`: restores the active session in place
    /// from a checkpoint entry; without one the host picks it
    /// (``chooseCheckpointEntry()``, ``restoreFromCheckpoint(entryID:)``).
    func restoreCheckpointCommand(entrySpecifier: String) async -> ChatCommandOutcome {
        do {
            let outcome: ChatSessionOperationOutcome
            if entrySpecifier.isEmpty {
                outcome = try await chooseCheckpointEntry()
            } else {
                outcome = try await restoreFromCheckpoint(entryID: entrySpecifier)
            }
            return ChatCommandOutcome(notices: outcome.notices)
        } catch {
            return Self.failedCommand(error)
        }
    }
}
