//
//  ZenWindowSession+Lines.swift
//  ZenApp
//
//  The lines of a window: the routing of a submitted line, the serial
//  executor, the flow of a line and of its turn, the stop, the prompt
//  history, and the attachments.
//

import Foundation
import ToolCore
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Lines

    /// A line of the window runs: a line of the executor (``isBusy``), or a
    /// turn adopted from Telegram, which runs as its line.
    var isLineRunning: Bool {
        isBusy || adoptedTelegramPromptID != nil
    }

    /// A line of the window runs or waits; a turn adopted from Telegram runs
    /// as its line.
    var isLineRunningOrWaiting: Bool {
        isLineRunning || !queuedLines.isEmpty
    }

    /// Submits ``draft``: records it in the prompt history and routes it as
    /// the terminal does: a leading live `@mention` is sent to the shared
    /// chat at once, even while a line runs, and never queued (one without a
    /// message is refused, and so is every one while Telegram drives the
    /// slot); any other line goes through ``ZenLineRoute``. The draft is
    /// cleared unless the line is refused. A blank draft does nothing.
    public func submitDraft() {
        let line = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !isClosed else { return }
        history.record(line)
        switch SharedChatMentionParser.parse(from: line, readableHandles: mentionHandles) {
        case let .route(mention):
            // A refused line: the draft is kept.
            guard !refusedWhileDormant() else { return }
            draft = ""
            sendMention(mention, line: line)
        case .missingText:
            appendLocalNow(.local(text: Self.mentionMissingTextMessage, isFailure: true))
        case .none:
            if route(line) {
                draft = ""
            }
        }
    }

    /// Runs `line` through the window's executor, routed like a submitted
    /// line, without touching the draft or the history. The conversation is
    /// selected first, so the line's result shows (the menu and toolbar
    /// commands come here).
    public func run(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isClosed else { return }
        selectTab(.chat)
        route(trimmed)
    }

    /// Routes `line`; `false` when it was refused.
    @discardableResult
    func route(_ line: String) -> Bool {
        let route = ZenLineRoute.route(
            for: line,
            // A turn adopted from Telegram runs as the window's line.
            isLineRunning: isLineRunning,
            // While Telegram drives the slot the queue waits, whole, for
            // `/telegram off`, which must run now rather than wait behind it:
            // every line runs, and `perform` refuses all but the lines that
            // take the slot back.
            hasQueuedLines: !isDrivenFromTelegram && !queuedLines.isEmpty,
            registry: ZenAppCommands.registry,
            context: commandContext
        )
        switch route {
        case .run:
            startLine(line)
        case .runBeside:
            startBeside(line)
        case .queue:
            guard queuedLines.count < Self.queueCapacity else {
                appendLocalNow(.local(text: Self.queueFullMessage, isFailure: true))
                return false
            }
            queuedLines.append(ZenQueuedLine(text: line))
            drainQueueIfIdle()
            sharedChatConsumerStateDidChange()
        case let .refuse(message):
            appendLocalNow(.local(text: message, isFailure: true))
            return false
        }
        return true
    }

    func startLine(_ line: String) {
        startExclusive { [weak self] stop in
            await self?.execute(line, stop: stop)
        }
    }

    /// Runs `work` as the one line of the executor, with a stop of its own
    /// (a stop of the previous line does not reach it); the queue drains
    /// after it.
    func startExclusive(_ work: @escaping @MainActor (ZenLineStop) async -> Void) {
        isBusy = true
        sharedChatConsumerStateDidChange()
        let stop = ZenLineStop()
        lineStop = stop
        lineTask = Task { [weak self] in
            await work(stop)
            self?.lineDidEnd()
        }
    }

    private func lineDidEnd() {
        lineTask = nil
        lineStop = nil
        isBusy = false
        guard !isClosed else { return }
        if statusFactsAreStale {
            scheduleStatusRefresh()
        }
        drainQueueIfIdle()
        sharedChatConsumerStateDidChange()
    }

    /// Starts the oldest queued line once nothing runs: not while Telegram
    /// drives the slot (the queue waits, whole, for `/telegram off`, as in the
    /// terminal) nor while a turn adopted from Telegram runs.
    func drainQueueIfIdle() {
        guard !isBusy, !isClosed, !isDrivenFromTelegram, adoptedTelegramPromptID == nil,
              !queuedLines.isEmpty else { return }
        let next = queuedLines.removeFirst()
        if next.isPlainPrompt {
            startPlainPrompt(next.text)
        } else {
            startLine(next.text)
        }
    }

    private func startBeside(_ line: String) {
        let token = UUID()
        besideTasks[token] = Task { [weak self] in
            // Stop ends the exclusive line, not a command beside it.
            await self?.execute(line, stop: ZenLineStop())
            guard let self else { return }
            self.besideTasks[token] = nil
            if self.statusFactsAreStale, !self.isBusy, self.besideTasks.isEmpty {
                self.scheduleStatusRefresh()
            }
        }
    }

    /// Removes a prompt from the queue before it runs.
    public func removeQueuedLine(_ id: UUID) {
        queuedLines.removeAll { $0.id == id }
        sharedChatConsumerStateDidChange()
    }

    /// The flow of one line (Docs/embedding.md, "Running a Line"), then the
    /// status facts when the line may have changed them, and the git summary.
    /// `stop` keeps a turn the line builds from starting once the operator
    /// stopped the line.
    private func execute(_ line: String, stop: ZenLineStop) async {
        guard !isClosed else { return }
        await perform(line, stop: stop)
        guard !isClosed else { return }
        if ZenAppCommands.changesStatusFacts(line) {
            statusFactsAreStale = true
        }
        if statusFactsAreStale {
            await refreshStatus()
        }
        refreshGitStatus()
    }

    private func perform(_ line: String, stop: ZenLineStop) async {
        if case let .refused(text) = await sessionHost.admitLine(line, in: slotID) {
            await appendLocal(.local(text: text, isFailure: true))
            return
        }
        guard let incarnation = await sessionHost.incarnation(in: slotID) else {
            await appendLocal(.local(text: Self.text(for: ChatSessionHostError.noSession), isFailure: true))
            return
        }
        let controller = incarnation.controller
        var prompt = line
        var purpose = ChatTurnPurpose.normal
        var typedByOperator = true

        let isCommand = line.hasPrefix("/")
        let outcome: ChatCommandOutcome?
        if isCommand {
            await appendLocal(.commandLine(line))
            outcome = await controller.handleCommandLine(line, context: commandContext)
        } else {
            // Read before the reply runs, so its echo precedes what it shows.
            let anchor = await ZenWindowSteps.anchor(in: sessionHost, slotID: slotID)
            outcome = await controller.pendingReplyAction(for: line)
            if let outcome, !Self.startsVisibleTurn(outcome) {
                echoReply(line, anchor: anchor)
            }
        }
        guard !isClosed else { return }
        if let outcome {
            await ZenWindowSteps.present(outcome.notices, in: sessionHost, slotID: slotID)
            if isCommand, ZenAppCommands.registry.descriptor(forLine: line)?.command == "/tasks" {
                await showRequestedTaskGraph()
            }
            switch outcome.action {
            case let .startTurn(commandPrompt, commandPurpose, locksResponseLanguage):
                prompt = commandPrompt
                purpose = commandPurpose
                typedByOperator = locksResponseLanguage
            case .channelCommand:
                await runChannelCommand(line)
                return
            default:
                return
            }
        }
        guard !isClosed else { return }
        await runTurn(
            prompt: prompt,
            purpose: purpose,
            typedByOperator: typedByOperator,
            stop: stop,
            controller: controller
        )
    }

    /// `true` when `outcome` starts a turn whose prompt shows: one the
    /// operator typed.
    private static func startsVisibleTurn(_ outcome: ChatCommandOutcome) -> Bool {
        if case let .startTurn(_, _, locksResponseLanguage) = outcome.action {
            return locksResponseLanguage
        }
        return false
    }

    /// The commands only the window runs: `/exit`, `/artifacts`, which
    /// toggles the artifacts sidebar (with arguments it answers the core's
    /// notice and toggles nothing), `/telegram`
    /// (``runTelegramCommand(_:)``), and `/voice`, which the app's voice
    /// session runs once this window became the one it follows
    /// (``ZenAppRuntime/runVoiceCommand(_:from:)``); every other channel
    /// command of the shared layer is not offered by the app. While Telegram
    /// drives the slot, `/voice` never gets here: the host refuses it, as
    /// every line but `/telegram`, `/telegram off`, and `/exit`, before it
    /// runs (``perform(_:stop:)``).
    private func runChannelCommand(_ line: String) async {
        switch ZenAppCommands.registry.descriptor(forLine: line)?.command {
        case ZenAppCommands.exit.command:
            closeRequested = true
        case ZenAppCommands.artifacts.command:
            let arguments = ChatCommandRegistry.arguments(from: line, commandPrefix: ZenAppCommands.artifacts.command)
            if arguments.isEmpty {
                toggleArtifactsSidebar()
            } else {
                await ZenWindowSteps.present([.artifactsTakeNoArguments], in: sessionHost, slotID: slotID)
            }
        case ZenAppCommands.telegram.command:
            await runTelegramCommand(line)
        case ZenAppCommands.voice.command:
            await runtime?.runVoiceCommand(line, from: self)
        default:
            await appendLocal(.local(text: "`\(line)` is not available in the app.", isFailure: true))
        }
    }

    /// Shows the artifacts sidebar when it is hidden, hides it otherwise.
    public func toggleArtifactsSidebar() {
        isArtifactsSidebarPresented.toggle()
    }

    /// Runs one turn in one chat-actor step (see
    /// ``ZenWindowSteps/runTurn(_:controller:in:slotID:hooks:presenter:voiceHost:hiddenPrompts:didReserve:)``),
    /// then shows how it ended, and returns it.
    @discardableResult
    func runTurn(
        prompt: String,
        purpose: ChatTurnPurpose,
        typedByOperator: Bool,
        stop: ZenLineStop,
        controller: ChatSessionController
    ) async -> ZenTurnOutcome {
        let outcome = await ZenWindowSteps.runTurn(
            ZenTurnStart(prompt: prompt, purpose: purpose, typedByOperator: typedByOperator, stop: stop),
            controller: controller,
            in: sessionHost,
            slotID: slotID,
            hooks: hooks,
            presenter: presenter,
            voiceHost: voiceHost,
            hiddenPrompts: hiddenPrompts,
            didReserve: turnDidReserve
        )
        switch outcome {
        case .finished:
            break
        case let .refused(error):
            await appendLocal(.local(text: Self.text(for: error), isFailure: true))
        case .cancelledBeforeStart:
            await appendLocal(.local(text: Self.turnCancelledText, isFailure: false))
        case let .failed(error):
            if let failure = error as? ChatTurnFailure {
                if failure.isCancellation {
                    await appendLocal(.local(text: Self.turnCancelledText, isFailure: false))
                } else {
                    await appendLocal(.local(
                        text: "Turn failed: \(failure.underlying.localizedDescription)",
                        isFailure: true
                    ))
                }
            } else {
                await appendLocal(.local(text: error.localizedDescription, isFailure: true))
            }
        }
        return outcome
    }

    /// The cards of the graphs a `/tasks` line published (explicit overviews),
    /// significant or not, one per publication, after what the line showed
    /// (its echo, its notices): each stays where it is, apart from the card of
    /// a turn. A line that published none (another action, no graph) shows
    /// its notices only.
    private func showRequestedTaskGraph() async {
        guard let requested = await ZenWindowSteps.requestedTaskGraphs(
            in: sessionHost,
            slotID: slotID,
            presenter: presenter
        ) else { return }
        guard !isClosed else { return }
        for overview in requested.overviews {
            projection.insertLocal(ZenLocalTranscriptItem(
                epoch: requested.anchor.epoch,
                anchorSequence: requested.anchor.sequence,
                content: .taskGraph(overview)
            ))
        }
        if projection.composeIfNeeded() {
            transcript = projection.items
        }
    }

    // MARK: - Stop and answers

    /// Esc of the terminal: cancels the turn that runs (the host fences it
    /// and drops its reservation, then the line's task is cancelled) and
    /// refuses the open requests, so a command waiting for an answer unwinds.
    /// The line's stop is set at once, before anything suspends, so a turn
    /// the line has not started yet never starts, reserved or not. The queue
    /// is kept. A turn adopted from Telegram is stopped by the slot's
    /// Telegram channel; while Telegram drives the slot nothing is stopped,
    /// as the terminal's Esc does not stop a turn the chat runs.
    public func stop() {
        guard !isClosed else { return }
        lineStop?.request()
        let sessionHost = sessionHost
        let slotID = slotID
        let line = lineTask
        Task {
            if await ZenWindowSteps.stop(in: sessionHost, slotID: slotID) {
                line?.cancel()
            }
        }
    }

    /// Answers the pending request `requestID` of the session the slot runs
    /// now; `nil` refuses it.
    public func answer(_ requestID: UUID, with answer: ChatPendingRequest.Answer?) {
        guard !isClosed else { return }
        let sessionHost = sessionHost
        let slotID = slotID
        Task {
            await ZenWindowSteps.answer(requestID, with: answer, in: sessionHost, slotID: slotID)
        }
    }

    // MARK: - History

    /// Puts the previous prompt of the history in the draft (↑ of the
    /// terminal); `false` when there is nothing older.
    @discardableResult
    public func recallPreviousPrompt() -> Bool {
        guard let text = history.recallPrevious(currentDraft: draft) else { return false }
        draft = text
        return true
    }

    /// Puts the next prompt of the history in the draft, or the draft from
    /// before the recall past the newest one (↓ of the terminal); `false`
    /// when no recall is in progress.
    @discardableResult
    public func recallNextPrompt() -> Bool {
        guard let text = history.recallNext(currentDraft: draft) else { return false }
        draft = text
        return true
    }

    // MARK: - Attachments

    /// Stages `urls` for the next prompt, one `/attach` command per file, as
    /// one line of the executor. Refused while a line runs, and, with one
    /// row, while Telegram drives the slot.
    public func attach(_ urls: [URL]) {
        guard !isClosed, !urls.isEmpty else { return }
        guard !refusedWhileDormant() else { return }
        let lines = urls.map(Self.attachCommandLine(for:))
        guard !isBusy else {
            refuseWhileBusy(command: "/attach")
            return
        }
        startExclusive { [weak self] stop in
            for line in lines {
                await self?.execute(line, stop: stop)
            }
        }
    }

    /// `/attach "<path>"`, with the quotes and backslashes of the path
    /// escaped for the `/attach` argument splitter.
    static func attachCommandLine(for url: URL) -> String {
        let path = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "/attach \"\(escaped)\""
    }
}
