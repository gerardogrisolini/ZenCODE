//
//  ZenCommandLineView.swift
//  ZenApp
//
//  The echo of a typed slash command.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// The echo of a slash command the operator typed: monospaced and muted,
/// with the `/command` token in the accent color. It has no marker: the
/// disclosure chevron marks only the rows that expand.
public struct ZenCommandLineView: View {
    private let text: String

    @Environment(\.zenPalette) private var palette

    /// - Parameter text: The submitted line, such as `/tasks show build`.
    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        let line = ZenTranscriptText.inline(text, limit: 2_000) ?? ""
        let runs: [ZenTextRun]
        if let token = ZenTranscriptText.commandToken(in: line) {
            runs = [ZenTextRun(text: token.command, color: palette.accent, isBold: true)]
                + (token.arguments.isEmpty ? [] : [ZenTextRun(text: " " + token.arguments, color: palette.textMuted)])
        } else {
            runs = [ZenTextRun(text: line, color: palette.textMuted)]
        }
        return Text(AttributedString.zen(runs))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(ZenFonts.monoSmall)
    }
}

#Preview("Command line") {
    VStack(alignment: .leading, spacing: 8) {
        ZenCommandLineView(text: "/tasks show transcript-views")
        ZenCommandLineView(text: "/help")
    }
    .padding()
    .frame(width: 480)
}
