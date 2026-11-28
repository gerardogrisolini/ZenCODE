//
//  ZenWindowRoot.swift
//  ZenApp
//
//  One window of a workspace: opens its sessions when it appears, closes
//  them when the window closes, and lays out the sidebar and the selected
//  conversation.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript
import ZenCODECore

/// The window of `workspace` once the runtime is up. Its sessions live as
/// long as the NSWindow (``ZenWindowLifetime``): hiding the content (a
/// background tab, a minimized or ordered-out window) keeps it.
///
/// After a `--worktree` launch, closing the last workspace window opens the
/// Worktree window (``ZenWorktreeClosureWindow``) to ask how to close the
/// worktree before the app quits.
struct ZenWindowRoot: View {
    let runtime: ZenAppRuntime
    let workspace: URL

    @State private var lifetime = ZenWindowLifetime()

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let workspaceWindow = lifetime.workspaceWindow
        let session = workspaceWindow?.selectedSession
        content(window: workspaceWindow, session: session)
            .navigationTitle(session?.sessionTitle ?? "ZenCODE")
            .navigationSubtitle(Self.abbreviatedPath(of: workspace))
            .focusedSceneValue(\.zenWindowSession, session)
            .focusedSceneValue(\.zenWorkspaceWindow, workspaceWindow)
            .background {
                ZenWindowAccessor { [lifetime] window in
                    lifetime.attach(to: window)
                }
            }
            .onAppear {
                let show = openWindow
                runtime.showWorktreeClosure = { show(id: ZenWorktreeClosureWindow.id) }
                lifetime.open(runtime: runtime, workspace: workspace)
                lifetime.onWindowWillClose = Self.askWorktreeClosureIfLast(
                    lifetime: lifetime,
                    runtime: runtime
                )
            }
            .sheet(isPresented: Binding(
                get: { workspaceWindow?.isWorktreePromptPresented == true },
                set: { workspaceWindow?.isWorktreePromptPresented = $0 }
            )) {
                if let workspaceWindow {
                    ZenWorktreeSessionSheet(runtime: runtime, source: workspaceWindow)
                }
            }
            .onChange(of: workspaceWindow?.closeRequested ?? false) { _, requested in
                guard requested else { return }
                dismissWindow()
            }
    }

    @ViewBuilder
    private func content(window: ZenWorkspaceWindow?, session: ZenWindowSession?) -> some View {
        if let window, let session {
            ZenSessionWindow(window: window, session: session)
        } else if let openFailure = lifetime.openFailure {
            ZenWindowOpenFailureView(workspace: workspace, message: openFailure)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the window of `lifetime` runs when it closes: when it was the
    /// last workspace window and the worktree of a `--worktree` launch is
    /// still to close, the operator is asked and the Worktree window opens.
    /// It opens from here: the view of the closing window is being torn
    /// down, so its own `.onChange` may never run.
    private static func askWorktreeClosureIfLast(
        lifetime: ZenWindowLifetime,
        runtime: ZenAppRuntime
    ) -> @MainActor () -> Void {
        // Weak: the lifetime keeps this closure.
        { [weak lifetime] in
            guard let closure = runtime.worktreeClosure, closure.isPending,
                  !runtime.hasOpenWindow(otherThan: lifetime?.workspaceWindow?.sessions ?? []) else { return }
            runtime.requestLaunchWorktreeClosure()
        }
    }

    /// The workspace path with the home folder abbreviated to `~`.
    static func abbreviatedPath(of workspace: URL) -> String {
        ZenTranscriptText.abbreviatedPath(workspace.standardizedFileURL.path(percentEncoded: false))
    }

    /// The text of a failure to open a window.
    static func describe(_ error: any Error) -> String {
        if let hostError = error as? ChatSessionHostError {
            switch hostError {
            case .shutDown:
                return "ZenCODE is shutting down."
            default:
                return "Could not open a session: \(hostError)."
            }
        }
        if let localized = (error as? any LocalizedError)?.errorDescription {
            return localized
        }
        return error.localizedDescription
    }
}

/// The window when its session could not open.
struct ZenWindowOpenFailureView: View {
    let workspace: URL
    let message: String

    @Environment(\.zenPalette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(palette.failureMessage)
            Text(message)
                .foregroundStyle(palette.failureMessage)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text(ZenWindowRoot.abbreviatedPath(of: workspace))
                .font(ZenFonts.monoSmall)
                .foregroundStyle(palette.textMuted)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The split view of a window with an open session: the workspace sessions in
/// the sidebar, the conversation in the detail. It presents the pending
/// requests over any tab as sheets of the window, except the menus, which
/// are a popover over the composer (``ZenBottomChrome``), or over the
/// toolbar button that launched their command (``ZenWindowToolbar``).
struct ZenSessionWindow: View {
    let window: ZenWorkspaceWindow
    let session: ZenWindowSession

    var body: some View {
        NavigationSplitView {
            ZenSessionSidebar(window: window, session: session)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            ZenConversationScreen(session: session)
        }
        .zenPendingRequests(session.pendingRequest) { requestID, answer in
            session.answer(requestID, with: answer)
        }
    }
}

extension FocusedValues {
    /// The session of the key window, for the menu bar commands.
    @Entry var zenWindowSession: ZenWindowSession?
    /// The session container of the key window, for New Session.
    @Entry var zenWorkspaceWindow: ZenWorkspaceWindow?
}
