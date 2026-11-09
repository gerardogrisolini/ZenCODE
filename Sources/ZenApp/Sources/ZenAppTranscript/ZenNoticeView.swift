//
//  ZenNoticeView.swift
//  ZenApp
//
//  Session notices and `/goal` workflow notices.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The outcome of a session operation or a shared command.
///
/// A file-change summary is drawn as ``ZenFileChangeSummaryView``. Every other
/// notice, the artifact history included (the app opens the artifacts sidebar
/// instead) and a kind newer than the app, shows
/// `ChatSessionNoticeText.text(for:)` on its channel: system notices in
/// `systemMessage`, failures in `failureMessage`, Markdown notices through
/// the environment's ``ZenMarkdownRenderer``, and a channel newer than the
/// app as a system notice.
public struct ZenNoticeView: View {
    private let notice: ChatSessionNotice

    @Environment(\.zenMarkdownRenderer) private var renderer

    /// - Parameter notice: The notice to show.
    public init(notice: ChatSessionNotice) {
        self.notice = notice
    }

    public var body: some View {
        switch notice {
        case let .fileChangeSummary(summary, includesDiff):
            ZenFileChangeSummaryView(summary: summary, includesDiff: includesDiff)
        default:
            let text = ZenTranscriptText.trimmingTrailingNewlines(ChatSessionNoticeText.text(for: notice))
            switch notice.channel {
            case .system:
                ZenLocalMessageView(text: text, isFailure: false)
            case .failure:
                ZenLocalMessageView(text: text, isFailure: true)
            case .markdown:
                renderer.render(text, isStreaming: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            @unknown default:
                // A channel newer than the app: the notice text.
                ZenLocalMessageView(text: text, isFailure: false)
            }
        }
    }
}

/// A `/goal` workflow state change: `ChatSessionNoticeText.text(for:)` in
/// `operationalMessage`, with the `/tasks` commands it names in the accent
/// color.
public struct ZenWorkflowNoticeView: View {
    private let notice: ChatWorkflowNotice

    @Environment(\.zenPalette) private var palette

    /// - Parameter notice: The workflow notice to show.
    public init(notice: ChatWorkflowNotice) {
        self.notice = notice
    }

    public var body: some View {
        let text = ZenTranscriptText.bounded(
            ZenTranscriptText.trimmingTrailingNewlines(ChatSessionNoticeText.text(for: notice)),
            limit: ZenTranscriptText.longTextLimit
        )
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(AttributedString.zen(runs(for: text)))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runs(for text: String) -> [ZenTextRun] {
        var runs: [ZenTextRun] = []
        var remaining = Substring(text)
        while let range = ["/tasks clear", "/tasks"]
            .compactMap({ remaining.range(of: $0) })
            .min(by: { lhs, rhs in
                lhs.lowerBound != rhs.lowerBound
                    ? lhs.lowerBound < rhs.lowerBound
                    : lhs.upperBound > rhs.upperBound
            }) {
            runs.append(ZenTextRun(text: String(remaining[..<range.lowerBound]), color: palette.operationalMessage))
            runs.append(ZenTextRun(text: String(remaining[range]), color: palette.accent))
            remaining = remaining[range.upperBound...]
        }
        runs.append(ZenTextRun(text: String(remaining), color: palette.operationalMessage))
        return runs
    }

    private var icon: String {
        switch notice {
        case .awaitingReply: "questionmark.bubble"
        case .blocked: "exclamationmark.octagon"
        case .openWithoutQuestion: "circle.dashed"
        case .recoverableFailure: "arrow.clockwise"
        @unknown default: "info.circle"
        }
    }

    private var iconColor: Color {
        switch notice {
        case .awaitingReply, .openWithoutQuestion: palette.operationalMessage
        case .blocked, .recoverableFailure: palette.statusQueued
        @unknown default: palette.operationalMessage
        }
    }
}

#Preview("Notices") {
    VStack(alignment: .leading, spacing: 12) {
        ZenNoticeView(notice: .sessionSaved(name: "refactor", messageCount: 42))
        ZenNoticeView(notice: .operationFailed(description: "the model is not available"))
        ZenNoticeView(notice: .help(commandHelp: ["/tasks — show the task graph", "/undo — revert the last changes"]))
        ZenWorkflowNoticeView(notice: .awaitingReply(graphID: "goal-1", pendingTaskCount: 2))
        ZenWorkflowNoticeView(notice: .blocked(graphID: "goal-1", message: "the build fails"))
    }
    .padding()
    .frame(width: 560)
}
