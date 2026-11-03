//
//  ZenLocalMessageView.swift
//  ZenApp
//
//  A message the app writes itself, on the system or the failure channel.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// A message of the app's own (an outcome, a status, a usage line, or an
/// error), in `systemMessage`, or in `failureMessage` for a failure.
public struct ZenLocalMessageView: View {
    private let text: String
    private let isFailure: Bool

    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - text: The message; trailing line breaks are dropped.
    ///   - isFailure: `true` for a refusal or an error.
    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }

    public var body: some View {
        Text(ZenTranscriptText.bounded(
            ZenTranscriptText.trimmingTrailingNewlines(text),
            limit: ZenTranscriptText.longTextLimit
        ))
        .font(ZenFonts.monoSmall)
        .foregroundStyle(isFailure ? palette.failureMessage : palette.systemMessage)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Local messages") {
    VStack(alignment: .leading, spacing: 8) {
        ZenLocalMessageView(text: "Saved session \"refactor\" (42 messages).\n", isFailure: false)
        ZenLocalMessageView(text: "ZenCODE: the model is not available.\n", isFailure: true)
    }
    .padding()
    .frame(width: 480)
}
