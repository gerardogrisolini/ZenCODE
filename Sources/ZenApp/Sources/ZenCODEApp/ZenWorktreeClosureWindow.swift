//
//  ZenWorktreeClosureWindow.swift
//  ZenApp
//
//  The Worktree window shares its choices and results between local closes
//  and the end of a `--worktree` launch.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenCODECore

/// Shows the active worktree decision, if any. One observer follows the
/// native window, even if a local decision replaces its SwiftUI content.
struct ZenWorktreeClosureWindow: View {
    /// The identifier of the window scene.
    static let id = "zen-worktree-closure"

    let launcher: ZenAppLauncher
    @State private var closeObserver = ZenWindowCloseObserver()

    var body: some View {
        Group {
            if let runtime = launcher.readyRuntime, let closure = runtime.displayedWorktreeClosure {
                ZenWorktreeClosureView(
                    closure: closure,
                    closeObserver: closeObserver,
                    isLaunchClosure: closure === runtime.worktreeClosure
                )
                .id(ObjectIdentifier(closure))
            } else {
                ZenWorktreeClosureUnrequestedView()
            }
        }
        .background {
            ZenWindowAccessor { [closeObserver, launcher] window in
                closeObserver.attach(to: window) {
                    guard let runtime = launcher.readyRuntime, let closure = runtime.displayedWorktreeClosure else {
                        return
                    }
                    if closure === runtime.worktreeClosure {
                        ZenWorktreeClosureView.windowWillClose(closure: closure)
                    } else {
                        runtime.dismissMenuWorktreeClosure(closure)
                    }
                }
            }
        }
    }
}

/// The Worktree window when there is nothing to ask: it closes at once.
private struct ZenWorktreeClosureUnrequestedView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task {
                dismissWindow(id: ZenWorktreeClosureWindow.id)
            }
    }
}

/// Shared choices, confirmation, progress, and results. Only a launch
/// decision quits the entire app.
struct ZenWorktreeClosureView: View {
    let closure: ZenWorktreeClosure
    let closeObserver: ZenWindowCloseObserver
    let isLaunchClosure: Bool

    @State private var isConfirmingRemoval = false

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.zenPalette) private var palette

    /// The branch the merge goes into, as the window names it before the
    /// repository was read.
    nonisolated static let mainBranchFallback = "the main branch"

    /// The branch the merge goes into.
    nonisolated static func targetBranch(of inspection: AgentWorktreeManager.Inspection?) -> String {
        inspection?.mainBranch ?? mainBranchFallback
    }

    /// The title of the merge button.
    nonisolated static func mergeTitle(into branch: String) -> String {
        "Merge into \(branch) and remove"
    }

    /// What the window shows while `action` runs.
    nonisolated static func progressText(for action: AgentWorktreeManager.ClosingAction) -> String {
        switch action {
        case .merge:
            "Merging…"
        case .discard:
            "Removing…"
        case .keep:
            "Closing…"
        }
    }

    var body: some View {
        content
            .padding(28)
            .frame(width: 460)
            .navigationTitle("Worktree")
            .windowDismissBehavior(closure.isRunning ? .disabled : .automatic)
            .task {
                await closure.load()
            }
            .onChange(of: closure.phase) { _, phase in
                if isLaunchClosure, case let .finished(outcome) = phase, outcome.succeeded {
                    quit()
                }
            }
            .confirmationDialog(
                "Remove the worktree and its branch?",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    decide(.discard)
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    @ViewBuilder
    private var content: some View {
        switch closure.phase {
        case .choosing:
            choosing
        case let .running(action):
            running(action)
        case let .finished(outcome):
            finished(outcome)
        }
    }

    // MARK: - Phases

    private var choosing: some View {
        let worktree = closure.worktree
        let inspection = closure.inspection
        return VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 36))
                    .foregroundStyle(palette.accent)
                Text(verbatim: "Worktree \(worktree.name)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(verbatim: ZenWindowRoot.abbreviatedPath(of: worktree.directory))
                    .font(ZenFonts.monoSmall)
                    .foregroundStyle(palette.textMuted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if inspection?.hasUncommittedChanges == true {
                Text("Uncommitted changes will be committed first")
                    .font(.callout)
                    .foregroundStyle(palette.textMuted)
            }
            if let loadFailure = closure.loadFailure {
                Text(verbatim: loadFailure)
                    .font(.callout)
                    .foregroundStyle(palette.failureMessage)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !closure.canModifyWorktree {
                Text("Wait for the current worktree operation to finish before merging or removing.")
                    .font(.callout)
                    .foregroundStyle(palette.textMuted)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button {
                    decide(.keep)
                } label: {
                    Text("Keep worktree")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(palette.accent)
                .keyboardShortcut(.defaultAction)
                Button {
                    decide(.merge)
                } label: {
                    Text(verbatim: Self.mergeTitle(into: Self.targetBranch(of: inspection)))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(inspection == nil || !closure.canModifyWorktree)
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Text("Remove without merging")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(inspection == nil || !closure.canModifyWorktree)
            }
            .controlSize(.large)
        }
    }

    private func running(_ action: AgentWorktreeManager.ClosingAction) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(palette.accent)
            Text(verbatim: Self.progressText(for: action))
                .foregroundStyle(palette.textMuted)
        }
        .padding(.vertical, 24)
    }

    private func finished(_ outcome: AgentWorktreeManager.ClosingOutcome) -> some View {
        VStack(spacing: 16) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(outcome.succeeded ? palette.statusSuccess : palette.failureMessage)
            ScrollView {
                Text(verbatim: outcome.lines.joined(separator: "\n"))
                    .font(ZenFonts.monoSmall)
                    .foregroundStyle(outcome.succeeded ? palette.textSecondary : palette.failureMessage)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            Button(isLaunchClosure ? "Quit ZenCODE" : "Done") {
                if isLaunchClosure { quit() } else { dismissWindow(id: ZenWorktreeClosureWindow.id) }
            }
            .buttonStyle(.glassProminent)
            .tint(palette.accent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
    }

    // MARK: - Actions

    private func decide(_ action: AgentWorktreeManager.ClosingAction) {
        Task {
            await closure.decide(action)
        }
    }

    /// Quits the app; the close of the window that follows asks nothing.
    private func quit() {
        closeObserver.stop()
        NSApp.terminate(nil)
    }

    /// The window closes: without a choice the worktree is kept, then the
    /// app quits; once the work ended, the app quits. This view is gone by
    /// then, so the task quits by itself.
    fileprivate static func windowWillClose(closure: ZenWorktreeClosure) {
        guard closure.isRequested else { return }
        switch closure.phase {
        case .choosing:
            Task {
                await closure.decide(.keep)
                NSApp.terminate(nil)
            }
        case .running:
            // The window cannot close while the work runs
            // (`windowDismissBehavior`).
            break
        case .finished:
            NSApp.terminate(nil)
        }
    }
}

/// Tells once when the NSWindow that hosts a view really closes
/// (`NSWindow.willCloseNotification`), not when SwiftUI only hides the
/// content (a minimized or ordered-out window, a background tab).
@MainActor
final class ZenWindowCloseObserver {
    private weak var window: NSWindow?
    private var observer: (any NSObjectProtocol)?
    private var onClose: (@MainActor () -> Void)?
    /// ``stop()`` ran, or the window closed: nothing is observed any more.
    private var isStopped = false

    init() {}

    /// Observes the closing of `window`; `onClose` runs once when it closes.
    /// A later call replaces `onClose`, and moves the observation when the
    /// window is another one. Nothing once stopped.
    func attach(to window: NSWindow, onClose: @escaping @MainActor () -> Void) {
        guard !isStopped else { return }
        self.onClose = onClose
        guard window !== self.window else { return }
        removeObserver()
        self.window = window
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            // Keep the observer alive through SwiftUI tearing down the view.
            MainActor.assumeIsolated {
                self.windowWillClose()
            }
        }
    }

    /// Stops observing for good: a later close runs nothing.
    func stop() {
        isStopped = true
        removeObserver()
        onClose = nil
    }

    private func windowWillClose() {
        let onClose = onClose
        stop()
        onClose?()
    }

    private func removeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        window = nil
    }
}
