//
//  ZenWorktreeClosureWindow.swift
//  ZenApp
//
//  The Worktree window of a `--worktree` launch: before the app quits, it
//  asks whether to merge the worktree into the main branch, keep it, or
//  remove it without merging, shows the work while it runs, and quits once
//  it is done.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenCODECore

/// The content of the Worktree window.
///
/// It shows the closing of the worktree only once the operator is asked
/// (``ZenWorktreeClosure/isRequested``): when the last workspace window
/// closes, or on a quit. Shown otherwise (no runtime, no worktree, not
/// asked) it draws nothing and closes itself.
struct ZenWorktreeClosureWindow: View {
    /// The identifier of the window scene.
    static let id = "zen-worktree-closure"

    let launcher: ZenAppLauncher

    var body: some View {
        if let closure = launcher.readyRuntime?.worktreeClosure, closure.isRequested {
            ZenWorktreeClosureView(closure: closure)
        } else {
            ZenWorktreeClosureUnrequestedView()
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

/// Asks how to close the worktree, shows the work while it runs, then quits
/// the app, or shows why the work failed.
///
/// Closing the window without a choice keeps the worktree, then quits; once
/// the work ended, closing it quits. It cannot be closed while the work
/// runs. The close is the one of the hosting NSWindow
/// (``ZenWindowCloseObserver``), not the content disappearing, which SwiftUI
/// also reports for a minimized window or a background tab.
struct ZenWorktreeClosureView: View {
    let closure: ZenWorktreeClosure

    @State private var isConfirmingRemoval = false
    @State private var closeObserver = ZenWindowCloseObserver()

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
            .background {
                ZenWindowAccessor { [closeObserver, closure] window in
                    closeObserver.attach(to: window) {
                        Self.windowWillClose(closure: closure)
                    }
                }
            }
            .task {
                await closure.load()
            }
            .onChange(of: closure.phase) { _, phase in
                if case let .finished(outcome) = phase, outcome.succeeded {
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
                .disabled(inspection == nil)
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Text("Remove without merging")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(inspection == nil)
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
            Button("Quit ZenCODE") {
                quit()
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
    private static func windowWillClose(closure: ZenWorktreeClosure) {
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
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowWillClose()
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
