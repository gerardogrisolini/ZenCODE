//
//  ZenWelcomeView.swift
//  ZenApp
//
//  The empty state of a session, like the terminal's startup banner.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// The empty state of a session: the `ZenCODE` wordmark in the startup-logo
/// color, the workspace path (abbreviated with `~`), the model, and the hint
/// to type a message or `/` for commands.
public struct ZenWelcomeView: View {
    private let workspace: URL
    private let modelID: String?

    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - workspace: The working directory of the session.
    ///   - modelID: The current model, or `nil` when none is selected.
    public init(workspace: URL, modelID: String?) {
        self.workspace = workspace
        self.modelID = modelID
    }

    public var body: some View {
        VStack(spacing: 14) {
            Text("ZenCODE")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(palette.startupLogo)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 6) {
                Label {
                    Text(ZenTranscriptText.abbreviatedPath(workspace.standardizedFileURL.path))
                        .foregroundStyle(palette.textSecondary)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(palette.accentCount)
                }
                Label {
                    Text(ZenTranscriptText.nonBlank(modelID).flatMap { ZenTranscriptText.inline($0, limit: 160) }
                        ?? "No model selected")
                        .foregroundStyle(modelID == nil ? palette.textMuted : palette.textSecondary)
                } icon: {
                    Image(systemName: "cpu")
                        .foregroundStyle(palette.accentCount)
                }
            }
            .font(.callout.monospaced())
            .textSelection(.enabled)
            Text("Type a message, or / for commands")
                .font(.callout)
                .foregroundStyle(palette.textMuted)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Welcome dark") {
    ZenWelcomeView(
        workspace: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects/ZenCODE"),
        modelID: "claude-opus-4"
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}

#Preview("Welcome light") {
    ZenWelcomeView(workspace: URL(fileURLWithPath: "/tmp/project"), modelID: nil)
        .frame(width: 640, height: 420)
        .preferredColorScheme(.light)
}
