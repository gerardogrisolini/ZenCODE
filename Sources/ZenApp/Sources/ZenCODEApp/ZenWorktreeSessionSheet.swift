//
//  ZenWorktreeSessionSheet.swift
//  ZenApp
//
//  Asks for a worktree before opening a session in its workspace.
//

import Foundation
import SwiftUI
import ZenAppSession
import ZenCODECore

struct ZenWorktreeSessionSheet: View {
    let runtime: ZenAppRuntime
    let source: ZenWorkspaceWindow
    @State private var request = ZenWorktreeSessionRequest()
    @State private var blockedMessage: String?
    @State private var isSubmitting = false
    @FocusState private var nameIsFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session with Worktree")
                .font(.headline)
            Text("Enter the name of the worktree to create or reuse.")
            TextField("Worktree name", text: $request.name)
                .focused($nameIsFocused)
                .disabled(isSubmitting)
                .onSubmit { confirm() }
            if let error = blockedMessage ?? request.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                if isSubmitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { source.isWorktreePromptPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("Create Session") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { nameIsFocused = true }
    }

    private func confirm() {
        guard !isSubmitting, !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            guard source.isWorktreePromptPresented, !source.isClosed, !source.closeRequested else { return }
            blockedMessage = nil
            guard runtime.beginWorktreePreparation() else {
                blockedMessage = "Wait for the current worktree operation to finish, then try again."
                return
            }
            defer { runtime.endWorktreePreparation() }
            let name = request.name
            guard let workspace = await request.confirm(in: source.workspace),
                  source.isWorktreePromptPresented, !source.isClosed, !source.closeRequested,
                  !runtime.isShutDown else { return }
            let opened = await runtime.openWorktreeSession(AgentWorktree(name: name, directory: workspace)) {
                openWindow(value: $0)
            }
            if opened {
                source.isWorktreePromptPresented = false
            } else {
                blockedMessage = "Finish the open Worktree dialog before opening this workspace."
            }
        }
    }
}
