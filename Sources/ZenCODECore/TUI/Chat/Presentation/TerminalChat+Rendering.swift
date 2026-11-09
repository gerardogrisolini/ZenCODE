//
//  TerminalChat+Rendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

struct TerminalChatBoldBreakState {
    var previousCharacter: Character?
    var pendingAsterisk = false
    var isBoldSpanOpen = false
}

extension TerminalChat {
    public func printActiveToolsIfNeeded() async {
        guard !didPrintActiveTools else {
            return
        }
        didPrintActiveTools = true
        await printToolSelectionStatus()
    }

    /// See ``ChatSessionController/resolvedActiveToolNames(fallbackAllowedToolNames:)``.
    func resolvedActiveToolNames(
        fallbackAllowedToolNames: Set<String>
    ) async -> [String] {
        await chatSession.resolvedActiveToolNames(
            fallbackAllowedToolNames: fallbackAllowedToolNames
        )
    }

    nonisolated static func resolvedActiveToolNames(
        fallbackAllowedToolNames: Set<String>,
        activeDescriptors: [DirectToolDescriptor]
    ) -> [String] {
        ChatSessionController.resolvedActiveToolNames(
            fallbackAllowedToolNames: fallbackAllowedToolNames,
            activeDescriptors: activeDescriptors
        )
    }

    public func printStartupSummary() async {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: false
        )
        let activeToolNames = await resolvedActiveToolNames(
            fallbackAllowedToolNames: allowedToolNames
        )
        let toolItems = await toolSelectionItems()
        didPrintActiveTools = true

        var lines = [
            "Version: \(Self.appVersionDescription)",
            Self.renderActiveTools(
                activeToolNames,
                items: toolItems,
                selectedKeys: selectedToolKeys
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let selectedAgent {
            lines.insert("Agent: \(selectedAgent.displayName)", at: 1)
        }

        let activeSkills = Self.renderActiveSkills(chatSession.selectedPromptSkills())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(activeSkills)

        let commands = "Commands: \(visibleCommandNamesForCurrentAgent().joined(separator: ", "))"

        lines.append(contentsOf: Self.startupWorkspaceLines(
            workingDirectory: configuration.workingDirectory,
            worktree: configuration.worktree
        ))
        lines.append(contentsOf: [
            "",
            commands
        ])

        let startupBox = Self.renderStartupBox(lines: lines)
        await renderCoordinator.writeStartupSummary(startupBox + "\n")
    }

    /// The workspace lines of the startup summary: the worktree of a
    /// `--worktree` launch (whose branch has its name), then the working
    /// directory.
    nonisolated static func startupWorkspaceLines(
        workingDirectory: URL,
        worktree: AgentWorktree?
    ) -> [String] {
        var lines: [String] = []
        if let worktree {
            lines.append("Worktree: \(worktree.name) (branch \(worktree.name))")
        }
        lines.append("Working directory: \(workingDirectory.path)")
        return lines
    }

    public func toolCompletionSummary(
        toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> String {
        guard toolCall.name == "local.exec",
              let command = (toolCall.argumentsObject["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return result.summary
        }

        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCommand = Self.truncatedInline(command, limit: 120)
        guard summary != "exit_code: 0" else {
            return displayCommand
        }
        return "\(displayCommand) (\(summary))"
    }

    public nonisolated static func renderActiveTools(_ toolNames: [String]) -> String {
        renderActiveTools(toolNames, items: [], selectedKeys: [])
    }

    public nonisolated static func renderActiveTools(
        _ toolNames: [String],
        items: [TerminalToolSelectionItem],
        selectedKeys: Set<String>
    ) -> String {
        ChatSessionNoticeText.text(
            for: .activeTools(
                ChatActiveToolsSummary(
                    toolNames: toolNames,
                    items: items,
                    selectedKeys: selectedKeys
                )
            )
        )
    }

    public nonisolated static func renderActiveSkills(_ skills: [PromptSkill]) -> String {
        renderSkills(skills, label: "Active")
    }

    private nonisolated static func renderSkills(
        _ skills: [PromptSkill],
        label: String
    ) -> String {
        guard !skills.isEmpty else {
            return "\(label) skills: none\n"
        }
        return "\(label) skills: \(skills.map(\.title).joined(separator: ", "))\n"
    }

    public nonisolated static func renderStartupBox(lines: [String]) -> String {
        let contentWidth = max(20, TerminalTextMetrics.terminalColumnCount())
        let logoStyle = TerminalStyle.Chrome.startupLogo
        let reset = TerminalStyle.reset

        var output: [String] = ["\(logoStyle)\(TerminalChat.zenCODEHeader)\(reset)"]
        for line in lines {
            let splitLines = line.components(separatedBy: .newlines)
            for splitLine in splitLines {
                let wrappedLines = wrapInline(splitLine, width: contentWidth)
                for (index, wrappedLine) in wrappedLines.enumerated() {
                    let colored = colorStartupLine(
                        wrappedLine,
                        isContinuation: index > 0
                    )
                    output.append("\(colored)\(reset)")
                }
            }
        }
        return output.joined(separator: "\n")
    }

    /// Colors a startup summary line so the label (up to the first colon) keeps
    /// the orange identity color while the value is rendered in a softer gray.
    /// Continuation lines (a long value wrapped onto extra rows) stay gray.
    private nonisolated static func colorStartupLine(
        _ line: String,
        isContinuation: Bool
    ) -> String {
        let orange = TerminalStyle.Accent.primary
        let gray = TerminalStyle.Text.secondary

        guard !isContinuation,
              let colonIndex = line.firstIndex(of: ":") else {
            return "\(gray)\(line)"
        }

        let label = line[...colonIndex]
        let value = line[line.index(after: colonIndex)...]
        return "\(orange)\(label)\(gray)\(value)"
    }

    public nonisolated static var zenCODEHeader: String {
        """
        ▀▀▀█           ▄▀▀▀ ▄▀▀▄ █▀▀▄ █▀▀▀
         ▄▀  ▄██▄ █▀▀▄ █    █  █ █  █ █▀▀
        █▄▄▄ ▀▄▄▄ █  █ ▀▄▄▄ ▀▄▄▀ █▄▄▀ █▄▄▄

        """
    }

    public nonisolated static var appVersionDescription: String {
        let version = bundleInfoString("CFBundleShortVersionString") ?? agentVersion
        guard let build = bundleInfoString("CFBundleVersion"),
              build != version else {
            return version
        }
        return "\(version) (\(build))"
    }

    public nonisolated static func bundleInfoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    /// Width of the terminal on the standard error (see
    /// ``TerminalTextMetrics/terminalColumnCount(forceRefresh:)``).
    public nonisolated static func terminalColumnCount(forceRefresh: Bool = false) -> Int {
        TerminalTextMetrics.terminalColumnCount(forceRefresh: forceRefresh)
    }

    /// Word-wraps `text` to at most `width` grapheme clusters per line, breaking
    /// on whitespace when possible.
    ///
    /// - Note: **Count-based family.** `width` is a `String.count` budget, so a
    ///   double-width emoji or CJK glyph is one unit here even when it occupies
    ///   two terminal columns. This matches ``truncatedInline(_:limit:)`` and
    ///   intentionally differs from the width-aware `fitDisplayWidth` /
    ///   ``TerminalANSIText`` family.
    public nonisolated static func wrapInline(_ text: String, width: Int) -> [String] {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard width > 0, singleLine.count > width else {
            return [singleLine]
        }

        var lines: [String] = []
        var remaining = singleLine[...]
        while remaining.count > width {
            let wrapEnd = remaining.index(remaining.startIndex, offsetBy: width)
            let candidate = remaining[..<wrapEnd]
            let breakIndex = candidate.lastIndex(where: { $0.isWhitespace })
            let lineEnd = breakIndex ?? wrapEnd
            let line = remaining[..<lineEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lines.append(String(line))
            }
            remaining = remaining[lineEnd...]
                .trimmingCharacters(in: .whitespacesAndNewlines)[...]
        }

        let finalLine = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalLine.isEmpty || lines.isEmpty {
            lines.append(finalLine)
        }
        return lines
    }

    /// Collapses `text` to a single line and truncates it to at most `limit`
    /// grapheme clusters. See ``InlineTextTruncation/truncatedInline(_:limit:)``.
    public nonisolated static func truncatedInline(_ text: String, limit: Int) -> String {
        InlineTextTruncation.truncatedInline(text, limit: limit)
    }
}
