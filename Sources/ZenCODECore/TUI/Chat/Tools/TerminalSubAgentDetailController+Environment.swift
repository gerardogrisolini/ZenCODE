//
//  TerminalSubAgentDetailController+Environment.swift
//  ZenCODE
//
//  The environment of the sub-agent detail controller: what it reads, waits
//  for and draws through.
//

import Foundation
import ToolCore

extension TerminalSubAgentDetailController {
    /// Everything the controller reads, waits for, and draws through.
    struct Environment {
        /// The snapshots of the session's sub-agents, now and after every
        /// change; `nil` when the session is not available, which ends the
        /// following.
        var snapshotEvents: @Sendable () async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>?
        /// The live transcript of an agent; `nil` when the session has no
        /// such agent or the agent's backend was shut down.
        var transcript: @Sendable (_ agentID: String) async -> ChatSubAgentTranscript?
        /// Waits for a duration; throws when its task is cancelled.
        var sleep: @Sendable (Duration) async throws -> Void
        /// The rows and columns of the panel's frame, read at every frame.
        var viewport: @ChatSessionActor () -> (rows: Int, columns: Int)
        /// Shows a frame: exactly `viewport().rows` lines, each
        /// `viewport().columns` wide.
        var present: @ChatSessionActor (_ lines: [String]) -> Void
        /// Whether the screen fell back to append-only output.
        var isCancelled: @ChatSessionActor () -> Bool
        /// Called once when the controller closes itself (``close(reason:)``).
        var onClosed: @ChatSessionActor (CloseReason) async -> Void
        /// Called when the panel moves between the agent list
        /// (`isChoosing`) and an agent's detail.
        var modeDidChange: @ChatSessionActor (_ isChoosing: Bool) async -> Void
        /// The title of a model identifier, for the model rows of the header
        /// and of the agent list.
        var modelTitleResolver: (String) -> String
        /// Whether the transcript rows carry ANSI styling.
        var standardErrorIsTerminal: Bool
        /// The shortest time between two applied updates that do not change
        /// the agent's lifecycle.
        var updateInterval: Duration
        /// The wait before a finished snapshot stream is subscribed again.
        var resubscribeInterval: Duration
        /// How often the viewport is compared with the last frame's.
        var viewportPollInterval: Duration
        /// Subscribes `observer` to the terminal resize signals and returns
        /// the cancellation of the subscription.
        var subscribeResize: (_ observer: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)

        init(
            snapshotEvents: @escaping @Sendable () async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>?,
            transcript: @escaping @Sendable (_ agentID: String) async -> ChatSubAgentTranscript?,
            viewport: @escaping @ChatSessionActor () -> (rows: Int, columns: Int),
            present: @escaping @ChatSessionActor (_ lines: [String]) -> Void,
            isCancelled: @escaping @ChatSessionActor () -> Bool,
            onClosed: @escaping @ChatSessionActor (CloseReason) async -> Void,
            modeDidChange: @escaping @ChatSessionActor (_ isChoosing: Bool) async -> Void = { _ in },
            modelTitleResolver: @escaping (String) -> String = { $0 },
            standardErrorIsTerminal: Bool,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            updateInterval: Duration = .milliseconds(500),
            resubscribeInterval: Duration = .seconds(1),
            viewportPollInterval: Duration = .milliseconds(200),
            subscribeResize: @escaping (_ observer: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
                = Environment.subscribeToTerminalResize
        ) {
            self.snapshotEvents = snapshotEvents
            self.transcript = transcript
            self.sleep = sleep
            self.viewport = viewport
            self.present = present
            self.isCancelled = isCancelled
            self.onClosed = onClosed
            self.modeDidChange = modeDidChange
            self.modelTitleResolver = modelTitleResolver
            self.standardErrorIsTerminal = standardErrorIsTerminal
            self.updateInterval = updateInterval
            self.resubscribeInterval = resubscribeInterval
            self.viewportPollInterval = viewportPollInterval
            self.subscribeResize = subscribeResize
        }

        /// The production ``subscribeResize``: a
        /// ``TerminalResizeCoordinator/shared`` subscription.
        static func subscribeToTerminalResize(
            _ observer: @escaping @Sendable () -> Void
        ) -> @Sendable () -> Void {
            let subscription = TerminalResizeCoordinator.shared.subscribe(observer)
            return { subscription.cancel() }
        }
    }
}
