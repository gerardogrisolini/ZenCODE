//
//  ChatSubAgentOverviewRefresher.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Publishes the sub-agent overview again and again while a blocking
/// `agent.*` tool call (such as `agent.wait`) executes, so the progress of the
/// sub-agents stays visible while the coordinator waits for them.
///
/// The controller owns one refresher (``ChatSessionController/subAgentOverviewRefresher``)
/// and the publication it runs, and the channel decides when, through
/// ``ChatSessionController/publishSubAgentOverviewIfChanged(relatedToolName:presenter:)``,
/// ``ChatSessionController/startSubAgentOverviewRefreshIfNeeded(presenter:)``, and
/// ``ChatSessionController/stopSubAgentOverviewRefresh(presenter:)``: the
/// terminal publishes after a sub-agent tool call starts and after it
/// settles, starts the refresh when a sub-agent tool call starts, and stops it
/// when the call settles and when the turn finishes. The shared turn calls
/// none of them, so a channel that does not present the overview (the ACP
/// bridge, the headless runner) neither reads the snapshots nor runs the
/// refresh.
///
/// Every tick waits ``interval``, runs ``onTick`` when set, and publishes. The
/// channel skips an overview whose signature it already rendered, so a tick
/// with nothing new writes nothing.
@ChatSessionActor
final class ChatSubAgentOverviewRefresher {
    /// The interval between two publications of the refresh.
    nonisolated static let defaultInterval: Duration = .seconds(2)

    /// How long each tick waits before it publishes. Read when the refresh
    /// starts; a test shortens it.
    var interval: Duration
    /// Runs at the start of every tick, before the publication; `nil` in
    /// production. A test awaits a gate there to hold a tick in flight. Read
    /// when the refresh starts.
    var onTick: (@Sendable () async -> Void)?
    /// Waits out ``interval``. A test replaces it with a gate it opens itself,
    /// before the refresh starts.
    var sleep: @Sendable (Duration) async throws -> Void

    /// The running refresh; `nil` while it is stopped.
    ///
    /// Only the channel's serial callbacks start and stop it, so a start and a
    /// stop never race; the refresh itself never reads it.
    private(set) var refreshTask: Task<Void, Never>?

    nonisolated init(
        interval: Duration = ChatSubAgentOverviewRefresher.defaultInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = ChatSubAgentOverviewRefresher.defaultSleep
    ) {
        self.interval = interval
        self.sleep = sleep
    }

    deinit {
        refreshTask?.cancel()
    }

    nonisolated static func defaultSleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    /// Starts the refresh of `controller`'s overview on `presenter`, unless it
    /// is already running. Idempotent.
    func startIfNeeded(
        for controller: ChatSessionController,
        presenter: any ChatSessionPresenter
    ) {
        guard refreshTask == nil else { return }
        let interval = interval
        let tick = onTick
        let sleep = sleep
        refreshTask = Task(name: "ZenCODE.Chat.sub-agent-overview-refresh") { [weak controller] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if let tick {
                    await tick()
                }
                guard !Task.isCancelled, let controller else { return }
                await controller.publishSubAgentOverview(presenter: presenter)
            }
        }
    }

    /// Cancels the refresh and waits for it to finish, so a tick in flight
    /// cannot publish an older overview after the caller's next publication
    /// (a bare cancel would leave that race open). Idempotent.
    func stop() async {
        let task = refreshTask
        refreshTask = nil
        task?.cancel()
        await task?.value
    }
}

// MARK: - Sub-agent overview

extension ChatSessionController {
    /// The running refresh of the sub-agent overview; `nil` while it is
    /// stopped.
    var subAgentOverviewRefreshTask: Task<Void, Never>? {
        subAgentOverviewRefresher.refreshTask
    }

    /// Publishes the sub-agent overview on `presenter` (the controller's own
    /// when `nil`). A `relatedToolName` that does not name a sub-agent tool
    /// publishes nothing: the publication around a tool call concerns only
    /// `agent.*` calls. Without a tool name it always publishes. The channel
    /// skips an overview whose signature it already rendered.
    func publishSubAgentOverviewIfChanged(
        relatedToolName: String? = nil,
        presenter: (any ChatSessionPresenter)? = nil
    ) async {
        if let relatedToolName,
           !DirectSubAgentRuntime.isSubAgentToolName(relatedToolName) {
            return
        }
        await publishSubAgentOverview(presenter: presenter ?? self.presenter)
    }

    /// Starts publishing the sub-agent overview on `presenter` (the
    /// controller's own when `nil`) every
    /// ``ChatSubAgentOverviewRefresher/interval``, unless the refresh already
    /// runs. Idempotent.
    func startSubAgentOverviewRefreshIfNeeded(
        presenter: (any ChatSessionPresenter)? = nil
    ) {
        subAgentOverviewRefresher.startIfNeeded(
            for: self,
            presenter: presenter ?? self.presenter
        )
    }

    /// Stops the refresh, waits for a tick in flight, and then publishes the
    /// overview once on `presenter` (the controller's own when `nil`), also
    /// when no refresh was running, so the latest state reaches the channel
    /// after every tick. Idempotent.
    func stopSubAgentOverviewRefresh(
        presenter: (any ChatSessionPresenter)? = nil
    ) async {
        await subAgentOverviewRefresher.stop()
        await publishSubAgentOverview(presenter: presenter ?? self.presenter)
    }

    /// Reserves a publication, reads the sub-agent snapshots, and presents
    /// them as an automatic overview. The reservation comes before the read,
    /// so a publication that starts later fences this one even when this
    /// read returns last.
    fileprivate func publishSubAgentOverview(presenter: any ChatSessionPresenter) async {
        let publication = await presenter.reserveSubAgentOverviewPublication()
        let snapshots = await runtime.subAgentSnapshots()
        await presenter.presentSubAgentOverview(
            ChatSubAgentOverview(snapshots: snapshots),
            origin: .automatic,
            publication: publication
        )
    }
}
