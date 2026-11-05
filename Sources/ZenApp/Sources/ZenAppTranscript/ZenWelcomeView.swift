//
//  ZenWelcomeView.swift
//  ZenApp
//
//  The empty state of a session, like the terminal's startup banner.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The empty state of a session, at the top left as the terminal's startup
/// banner: the `ZenCODE` wordmark in the startup-logo color; the lines of the
/// terminal's startup summary, with its labels in the accent orange and in
/// its order (the version, the agent, the active tools, the active skills,
/// and the working directory, abbreviated with `~`); and, after a gap, as the
/// last line, the commands the operator sees, as the terminal's `Commands:`
/// line.
public struct ZenWelcomeView: View {
    /// A line of the startup summary: its icon and the terminal's text.
    struct SummaryLine: Equatable {
        let systemImage: String
        let text: String

        /// The text up to its first colon, included, which the terminal
        /// colors orange; empty when the text has no colon, which the
        /// terminal colors gray as a whole.
        var label: String {
            guard let colon = text.firstIndex(of: ":") else {
                return ""
            }
            return String(text[...colon])
        }

        /// The text after the label, which the terminal colors gray.
        var value: String {
            String(text.dropFirst(label.count))
        }
    }

    private let summaryLines: [SummaryLine]
    private let commandsLine: SummaryLine?

    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - workspace: The working directory of the session.
    ///   - agentName: The selected agent's display name, or `nil` when none
    ///     is selected.
    ///   - activeTools: The tool groups the session exposes, or `nil` until
    ///     they are read.
    ///   - activeSkills: The skills the session selected, or `nil` until they
    ///     are read.
    ///   - commands: The commands the operator sees, in display order; empty
    ///     leaves the line out.
    ///   - version: The version, the terminal's by default.
    public init(
        workspace: URL,
        agentName: String? = nil,
        activeTools: ChatActiveToolsSummary? = nil,
        activeSkills: [PromptSkill]? = nil,
        commands: [String] = [],
        version: String = TerminalChat.appVersionDescription
    ) {
        self.summaryLines = Self.summaryLines(
            version: version,
            agentName: agentName,
            activeTools: activeTools,
            activeSkills: activeSkills,
            workspace: workspace
        )
        self.commandsLine = Self.commandsLine(commands)
    }

    /// The lines of the terminal's startup summary
    /// (`TerminalChat.printStartupSummary()`), with its texts: `Version:`,
    /// `Agent:` only when an agent is selected, `Active tools:` and
    /// `Active skills:` once they are read, and `Working directory:`, whose
    /// path is abbreviated with `~`.
    static func summaryLines(
        version: String,
        agentName: String?,
        activeTools: ChatActiveToolsSummary?,
        activeSkills: [PromptSkill]?,
        workspace: URL
    ) -> [SummaryLine] {
        var lines = [SummaryLine(systemImage: "info.circle", text: "Version: \(version)")]
        if let agentName {
            lines.append(SummaryLine(systemImage: "person.crop.circle", text: "Agent: \(agentName)"))
        }
        if let activeTools {
            lines.append(SummaryLine(
                systemImage: "wrench.and.screwdriver",
                text: ZenTranscriptText.trimmingTrailingNewlines(
                    ChatSessionNoticeText.text(for: .activeTools(activeTools))
                )
            ))
        }
        if let activeSkills {
            lines.append(SummaryLine(
                systemImage: "sparkles",
                text: ZenTranscriptText.trimmingTrailingNewlines(TerminalChat.renderActiveSkills(activeSkills))
            ))
        }
        lines.append(SummaryLine(
            systemImage: "folder",
            text: "Working directory: \(ZenTranscriptText.abbreviatedPath(workspace.standardizedFileURL.path))"
        ))
        return lines
    }

    /// The terminal's `Commands:` line of the startup summary
    /// (`TerminalChat.printStartupSummary()`): the command names, with their
    /// slash, separated by commas; `nil` when there are none.
    static func commandsLine(_ commands: [String]) -> SummaryLine? {
        guard !commands.isEmpty else {
            return nil
        }
        return SummaryLine(systemImage: "terminal", text: "Commands: " + commands.joined(separator: ", "))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ZenCODE")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(palette.startupLogo)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(summaryLines, id: \.systemImage) { line in
                    summaryLabel(line)
                }
                if let commandsLine {
                    summaryLabel(commandsLine)
                        // The blank line before the terminal's `Commands:` line.
                        .padding(.top, 12)
                }
            }
            .font(.callout.monospaced())
            .textSelection(.enabled)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A line with its icon and the terminal's colors.
    private func summaryLabel(_ line: SummaryLine) -> some View {
        Label {
            Text(styledText(line))
        } icon: {
            // One width for every icon, so the texts start in one column.
            Image(systemName: line.systemImage)
                .foregroundStyle(palette.accentCount)
                .frame(width: 20)
        }
    }

    /// The line as the terminal colors it: the label orange, the value gray.
    private func styledText(_ line: SummaryLine) -> AttributedString {
        var text = AttributedString(line.label)
        text.foregroundColor = palette.accent
        var value = AttributedString(line.value)
        value.foregroundColor = palette.textSecondary
        text.append(value)
        return text
    }
}

#Preview("Welcome dark") {
    ZenWelcomeView(
        workspace: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects/ZenCODE"),
        agentName: "Developer",
        activeTools: ChatActiveToolsSummary(groups: [
            .init(title: "Shell", toolCount: 2),
            .init(title: "Files", toolCount: 14),
            .init(title: "Search", toolCount: 3),
            .init(title: "Git", toolCount: 17),
        ]),
        activeSkills: [
            PromptSkill(canonicalName: "swift-testing", title: "Swift Testing Pro", summary: "", promptBody: "", sourceHash: "a"),
        ],
        commands: ["/help", "/models", "/think", "/agents", "/tools", "/skills", "/sessions", "/exit"]
    )
    .padding(24)
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}

#Preview("Welcome light") {
    ZenWelcomeView(
        workspace: URL(fileURLWithPath: "/tmp/project"),
        activeTools: ChatActiveToolsSummary(groups: []),
        activeSkills: []
    )
    .padding(24)
    .frame(width: 640, height: 420)
    .preferredColorScheme(.light)
}
