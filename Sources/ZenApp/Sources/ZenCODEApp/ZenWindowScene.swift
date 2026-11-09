//
//  ZenWindowScene.swift
//  ZenApp
//
//  The content of every window: the launch progress, the launch failure, or
//  the window of a workspace once the runtime is up.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript

/// The root of a window, following the launcher's phase. Once the operator
/// is asked how to close the worktree of a `--worktree` launch (a quit), it
/// opens the Worktree window.
struct ZenWindowScene: View {
    let launcher: ZenAppLauncher
    /// The workspace the window was opened for; `nil` is the launch one.
    let requestedWorkspace: URL?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch launcher.phase {
            case .launching:
                ZenLaunchingView()
            case let .failed(failure):
                ZenLaunchFailureView(failure: failure)
            case let .ready(runtime):
                ZenWindowRoot(
                    runtime: runtime,
                    workspace: (requestedWorkspace ?? runtime.launchWorkspace).standardizedFileURL
                )
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.zenMarkdownRenderer, .zenMarkdownView)
        .environment(\.zenCodeHighlighter, .zenSyntaxHighlighter)
        .onAppear { launcher.start() }
        .onChange(of: launcher.readyRuntime?.worktreeClosure?.isRequested ?? false) { _, requested in
            // Every workspace window asks; the Worktree window is single.
            if requested {
                openWindow(id: ZenWorktreeClosureWindow.id)
            }
        }
    }
}

/// The window while the runtime launches.
struct ZenLaunchingView: View {
    @Environment(\.zenPalette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(palette.accent)
            Text("Starting ZenCODE…")
                .foregroundStyle(palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("ZenCODE")
    }
}

/// The window when the runtime could not launch.
struct ZenLaunchFailureView: View {
    let failure: ZenAppLaunchFailure

    @Environment(\.zenPalette) private var palette

    /// The hint under the message of ``ZenAppLaunchFailure/startFailed(_:)``.
    nonisolated static let startFailedHint =
        "Run `zen --setup` in a terminal to set up ZenCODE, or `zen --doctor` to check it, then start the app again."

    /// The hint under the message of `failure`, if any: only a failed start
    /// has one. The message of ``ZenAppLaunchFailure/notConfigured(_:)``
    /// already asks to run `zen --setup`, and a wrong argument is shown alone.
    nonisolated static func hint(for failure: ZenAppLaunchFailure) -> String? {
        switch failure {
        case .startFailed:
            startFailedHint
        case .notConfigured, .invalidArguments:
            nil
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(palette.failureMessage)
            Text(failure.message)
                .foregroundStyle(palette.failureMessage)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 560)
            if let hint = Self.hint(for: failure) {
                Text(LocalizedStringKey(hint))
                    .font(.callout)
                    .foregroundStyle(palette.textMuted)
                    .multilineTextAlignment(.center)
            }
            Button("Quit ZenCODE") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.glassProminent)
            .tint(palette.accent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("ZenCODE")
    }
}
