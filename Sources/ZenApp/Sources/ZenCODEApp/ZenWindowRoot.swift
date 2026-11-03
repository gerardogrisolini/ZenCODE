//
//  ZenWindowRoot.swift
//  ZenApp
//
//  One window of a workspace: opens its session when it appears, closes it
//  when the window closes or the session asks to close (`/exit`), and lays
//  out the sidebar and the conversation.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript
import ZenCODECore

/// The window of `workspace` once the runtime is up. The session lives as
/// long as the NSWindow (``ZenWindowLifetime``): hiding the content (a
/// background tab, a minimized or ordered-out window) keeps it.
struct ZenWindowRoot: View {
    let runtime: ZenAppRuntime
    let workspace: URL

    @State private var lifetime = ZenWindowLifetime()

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let session = lifetime.session
        content(session: session)
            .navigationTitle(session?.sessionTitle ?? "ZenCODE")
            .navigationSubtitle(Self.abbreviatedPath(of: workspace))
            .focusedSceneValue(\.zenWindowSession, session)
            .background {
                ZenWindowAccessor { [lifetime] window in
                    lifetime.attach(to: window)
                }
            }
            .onAppear {
                lifetime.open(runtime: runtime, workspace: workspace)
            }
            .onChange(of: session?.closeRequested ?? false) { _, requested in
                guard requested else { return }
                lifetime.closeSession()
                dismissWindow()
            }
    }

    @ViewBuilder
    private func content(session: ZenWindowSession?) -> some View {
        if let session {
            ZenSessionWindow(session: session)
        } else if let openFailure = lifetime.openFailure {
            ZenWindowOpenFailureView(workspace: workspace, message: openFailure)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The split view of a window with an open session: the saved sessions in
/// the sidebar, the conversation in the detail.
struct ZenSessionWindow: View {
    let session: ZenWindowSession

    var body: some View {
        NavigationSplitView {
            ZenSessionSidebar(session: session)
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
}
