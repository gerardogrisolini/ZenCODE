//
//  ZenWorktreeClosure.swift
//  ZenApp
//
//  The end of a `--worktree NAME` launch of the app: before the app quits,
//  the operator merges the worktree into the main branch, keeps it, or
//  removes it without merging, as the terminal asks when its chat ends.
//

import Foundation
import Observation
import ZenCODECore

/// How the worktree of a `--worktree` launch is closed before the app quits.
///
/// The app asks once, in its Worktree window, when the last workspace window
/// closes or the operator quits (``request()``). ``load()`` reads the
/// repository for that window (`AgentWorktreeManager.inspect`): the main
/// branch and whether the worktree has uncommitted changes. ``decide(_:)``
/// shuts the runtime down first, so no session writes in the worktree any
/// more, then closes the worktree (`AgentWorktreeManager.perform`) and keeps
/// the outcome.
///
/// Keeping the worktree reads neither Git nor the inspection, so it works
/// also when the repository could not be inspected; merging and removing need
/// the inspection and are ignored without it.
@MainActor
@Observable
public final class ZenWorktreeClosure {
    /// Where the closing is.
    public enum Phase: Equatable, Sendable {
        /// The operator has not chosen yet.
        case choosing
        /// The runtime shuts down, then the action runs.
        case running(AgentWorktreeManager.ClosingAction)
        /// The action ended.
        case finished(AgentWorktreeManager.ClosingOutcome)
    }

    /// Reads the repository of a worktree (`AgentWorktreeManager.inspect`).
    public typealias Inspect = @MainActor (AgentWorktree) async throws -> AgentWorktreeManager.Inspection
    /// Closes a worktree (`AgentWorktreeManager.perform`); never throws.
    public typealias Perform = @MainActor (
        AgentWorktreeManager.ClosingAction,
        AgentWorktree,
        AgentWorktreeManager.Inspection
    ) async -> AgentWorktreeManager.ClosingOutcome

    /// The worktree of the launch.
    public let worktree: AgentWorktree
    /// The repository as ``load()`` read it; `nil` before it did and when it
    /// failed.
    public private(set) var inspection: AgentWorktreeManager.Inspection?
    /// Why ``load()`` could not read the repository, as the window shows it.
    public private(set) var loadFailure: String?
    /// The operator is asked how to close the worktree: the Worktree window
    /// must be open.
    public private(set) var isRequested = false
    /// Where the closing is.
    public private(set) var phase: Phase = .choosing

    /// The operator has not chosen yet.
    public var isPending: Bool {
        if case .choosing = phase { true } else { false }
    }

    /// The chosen action runs.
    public var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    @ObservationIgnored private let shutdown: @MainActor () async -> Void
    @ObservationIgnored private let inspect: Inspect
    @ObservationIgnored private let perform: Perform
    /// ``load()`` ran once already.
    @ObservationIgnored private var isLoadStarted = false

    /// - Parameters:
    ///   - worktree: The worktree of the launch.
    ///   - shutdown: Shuts the runtime down; ``decide(_:)`` runs it before
    ///     the action.
    ///   - inspect: Reads the repository; the Core's by default.
    ///   - perform: Closes the worktree; the Core's by default.
    public init(
        worktree: AgentWorktree,
        shutdown: @escaping @MainActor () async -> Void,
        inspect: @escaping Inspect = { try await AgentWorktreeManager.inspect($0) },
        perform: @escaping Perform = { action, worktree, inspection in
            await AgentWorktreeManager.perform(action, worktree: worktree, inspection: inspection)
        }
    ) {
        self.worktree = worktree
        self.shutdown = shutdown
        self.inspect = inspect
        self.perform = perform
    }

    /// Asks the operator how to close the worktree: ``isRequested`` becomes
    /// `true`, once.
    public func request() {
        guard !isRequested else { return }
        isRequested = true
    }

    /// Reads the repository into ``inspection``; a failure leaves it `nil`
    /// and is kept in ``loadFailure``. Only the first call reads, and only
    /// before a decision.
    public func load() async {
        guard !isLoadStarted, isPending else { return }
        isLoadStarted = true
        do {
            inspection = try await inspect(worktree)
            loadFailure = nil
        } catch {
            inspection = nil
            loadFailure = "Could not inspect the worktree \(worktree.name): \(error.localizedDescription)"
        }
    }

    /// Closes the worktree with `action`: shuts the runtime down, then runs
    /// the action, and ends in ``Phase/finished(_:)`` with its outcome.
    /// Ignored once a decision was taken, and for merging and removing
    /// without an ``inspection``; keeping needs none.
    public func decide(_ action: AgentWorktreeManager.ClosingAction) async {
        guard isPending else { return }
        let inspection: AgentWorktreeManager.Inspection
        if let loaded = self.inspection {
            inspection = loaded
        } else if action == .keep {
            inspection = Self.keepingInspection(of: worktree)
        } else {
            return
        }
        phase = .running(action)
        await shutdown()
        let outcome = await perform(action, worktree, inspection)
        phase = .finished(outcome)
    }

    /// What keeping the worktree passes when the repository was not
    /// inspected: `.keep` reads neither Git nor the inspection, so a
    /// placeholder stands in, as in the terminal.
    nonisolated static func keepingInspection(of worktree: AgentWorktree) -> AgentWorktreeManager.Inspection {
        AgentWorktreeManager.Inspection(
            mainRoot: worktree.directory,
            mainBranch: worktree.name,
            hasUncommittedChanges: false
        )
    }
}
