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

    public func printStartupSummary() async {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: false
        )
        let toolItems = await toolSelectionItems()
        didPrintActiveTools = true

        var lines = [
            "Version: \(Self.appVersionDescription)",
            Self.renderActiveTools(
                Array(allowedToolNames),
                items: toolItems,
                selectedKeys: selectedToolKeys
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let selectedAgent {
            lines.insert("Agent: \(selectedAgent.displayName)", at: 1)
        }

        let activeSkills = Self.renderActiveSkills(selectedPromptSkills())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(activeSkills)

        let commands = "Commands: \(visibleCommandNamesForCurrentAgent().joined(separator: ", "))"

        lines.append(contentsOf: [
            "Working directory: \(configuration.workingDirectory.path)",
            "",
            commands
        ])

        let startupBox = Self.renderStartupBox(lines: lines)
        await renderCoordinator.writeStartupSummary(startupBox + "\n")
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

    public static func renderActiveTools(_ toolNames: [String]) -> String {
        renderActiveTools(toolNames, items: [], selectedKeys: [])
    }

    public static func renderActiveTools(
        _ toolNames: [String],
        items: [TerminalToolSelectionItem],
        selectedKeys: Set<String>
    ) -> String {
        let uniqueToolNames = Set(toolNames).subtracting(AgentProfileStore.featureManagementToolNames)
        guard !uniqueToolNames.isEmpty else {
            return "Active tools: none\n"
        }

        var groupedToolNames = Set<String>()
        var renderedGroups: [String] = []
        let normalizedKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            selectedKeys,
            items: items
        )

        for item in items where normalizedKeys.contains(item.key) {
            let itemToolNames = uniqueToolNames.filter { item.allows(toolName: $0) }
            guard !itemToolNames.isEmpty else {
                continue
            }
            groupedToolNames.formUnion(itemToolNames)
            let concreteToolNames = itemToolNames.filter { toolName in
                !toolName.hasSuffix(".")
            }.sorted()
            let toolCount = concreteToolNames.count
            renderedGroups.append("\(item.title) (\(toolCount))")
        }

        let otherToolCount = uniqueToolNames.subtracting(groupedToolNames).count
        if otherToolCount > 0 {
            renderedGroups.append("Other (\(otherToolCount))")
        }

        guard !renderedGroups.isEmpty else {
            return "Active tools: none\n"
        }
        return "Active tools: \(renderedGroups.joined(separator: ", "))\n"
    }

    public static func renderSelectedSkills(_ skills: [PromptSkill]) -> String {
        guard !skills.isEmpty else {
            return "Selected skills: none\n"
        }

        let renderedSkills = skills
            .map(\.title)
            .joined(separator: ", ")
        return "Selected skills: \(renderedSkills)\n"
    }

    public static func renderActiveSkills(_ skills: [PromptSkill]) -> String {
        guard !skills.isEmpty else {
            return "Active skills: none\n"
        }

        let renderedSkills = skills
            .map(\.title)
            .joined(separator: ", ")
        return "Active skills: \(renderedSkills)\n"
    }

    public static func renderToolSelectionUsage() -> String {
        "Usage: /tools [all|none|tool-name|package-name|tool-number]\n"
    }

    public static func renderSkillSelectionUsage() -> String {
        "Usage: /skills [all|none|skill-name|skill-number|install <github-url|local-path>|<github-url|local-path>]\n"
    }

    public static func renderStartupBox(lines: [String]) -> String {
        let columns = terminalColumnCount()
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let contentWidth = max(20, columns - horizontalInset * 2)
                let linePrefix = String(repeating: " ", count: horizontalInset)
        let orange = "\u{1B}[38;5;208m"
        let reset  = "\u{001B}[0m"

        var output: [String] = ["\(orange)\(TerminalChat.zenCODEHeader)\(reset)"]
        for line in lines {
            let splitLines = line.components(separatedBy: .newlines)
            for splitLine in splitLines {
                let wrappedLines = wrapInline(splitLine, width: contentWidth)
                for (index, wrappedLine) in wrappedLines.enumerated() {
                    let colored = colorStartupLine(
                        wrappedLine,
                        isContinuation: index > 0
                    )
                    output.append("\(linePrefix)\(colored)\(reset)")
                }
            }
        }
        return output.joined(separator: "\n")
    }

    /// Colors a startup summary line so the label (up to the first colon) keeps
    /// the orange identity color while the value is rendered in a softer gray.
    /// Continuation lines (a long value wrapped onto extra rows) stay gray.
    private static func colorStartupLine(
        _ line: String,
        isContinuation: Bool
    ) -> String {
        let orange = "\u{1B}[38;5;208m"
        let gray = "\u{1B}[38;5;253m"

        guard !isContinuation,
              let colonIndex = line.firstIndex(of: ":") else {
            return "\(gray)\(line)"
        }

        let label = line[...colonIndex]
        let value = line[line.index(after: colonIndex)...]
        return "\(orange)\(label)\(gray)\(value)"
    }

    public static var zenCODEHeader: String {
        """
        ███████╗                 ██████╗ ██████╗ ██████╗ ███████╗
        ╚══███╔╝ █████╗ ██████╗ ██╔════╝██╔═══██╗██╔══██╗██╔════╝
          ███╔╝ ██╔══██╗██╔══██╗██║     ██║   ██║██║  ██║█████╗  
         ███╔╝  █████╔═╝██║  ██║██║     ██║   ██║██║  ██║██╔══╝  
        ███████╗██╔═══╝ ██║  ██║╚██████╗╚██████╔╝██████╔╝███████╗
        ╚══════╝╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝
        
        """
    }

    public static var appVersionDescription: String {
        let version = bundleInfoString("CFBundleShortVersionString") ?? agentVersion
        guard let build = bundleInfoString("CFBundleVersion"),
              build != version else {
            return version
        }
        return "\(version) (\(build))"
    }

    public static func bundleInfoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    public static func terminalColumnCount(forceRefresh: Bool = false) -> Int {
        TerminalWidth.current(
            descriptors: [AgentOutput.standardError.fileDescriptor],
            fallback: 100,
            forceRefresh: forceRefresh
        )
    }

    public static func terminalBoxHorizontalInset(columns _: Int? = nil) -> Int {
        return 0
    }

    /// Reflows `text` to a budget of `width` grapheme clusters per row and joins
    /// the wrapped rows with newlines.
    ///
    /// - Note: **Count-based family.** Like ``wrapInline(_:width:)`` and
    ///   ``truncatedInline(_:limit:)``, this measures extended grapheme clusters
    ///   (`String.count`), not visible terminal columns. It intentionally differs
    ///   from the width-aware `fitDisplayWidth` / ``TerminalANSIText`` family:
    ///   emoji and CJK glyphs count as one here even when they occupy two cells.
    ///   Routing these startup, overview, or Telegram helpers through the
    ///   width-aware core would change their wrap points.
    public static func fitInline(_ text: String, width: Int) -> String {
        wrapInline(text, width: width).joined(separator: "\n")
    }

    /// Word-wraps `text` to at most `width` grapheme clusters per line, breaking
    /// on whitespace when possible.
    ///
    /// - Note: **Count-based family.** `width` is a `String.count` budget, so a
    ///   double-width emoji or CJK glyph is one unit here even when it occupies
    ///   two terminal columns. This matches ``fitInline(_:width:)`` and
    ///   ``truncatedInline(_:limit:)`` and intentionally differs from the
    ///   width-aware `fitDisplayWidth` / ``TerminalANSIText`` family.
    public static func wrapInline(_ text: String, width: Int) -> [String] {
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

    public static func padded(_ text: String, width: Int) -> String {
        guard text.count < width else {
            return text
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>) -> Bool {
        allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    /// Collapses `text` to a single line and truncates it to at most `limit`
    /// grapheme clusters, appending an `...` ellipsis when content is cut and
    /// the marker fits the supplied budget.
    ///
    /// - Note: **Count-based family.** `limit` is measured in extended grapheme
    ///   clusters (`String.count`), so a double-width emoji or CJK glyph is one
    ///   unit even when it renders in two terminal columns. This deliberately
    ///   differs from width-aware `fitDisplayWidth` and
    ///   ``TerminalANSIText/truncate(_:to:)``: routing this helper through that
    ///   core would silently change startup, overview, and Telegram output. The
    ///   `...` glyph has a three-cluster budget, while its measurement remains
    ///   count-based.
    public static func truncatedInline(_ text: String, limit: Int) -> String {
        let singleLine = inlineText(text)
        return truncatedByCount(singleLine, limit: limit, ellipsis: "...")
    }

    /// Shared count-based truncation core for the inline (non-width) family.
    /// Cuts `text` to at most `limit` grapheme clusters, reserving room for
    /// `ellipsis` and appending it only when content is actually removed.
    ///
    /// This mirrors the parametric-ellipsis shape of the width-based core
    /// ``TerminalANSIText/truncate(_:to:ellipsis:ellipsisWidth:)`` so the two
    /// families read consistently, but it deliberately measures with
    /// `String.count`/`prefix` (one unit per grapheme) instead of visible
    /// columns. Callers are expected to have already flattened newlines
    /// (e.g. via ``inlineText(_:)``). No ANSI handling is performed because the
    /// count-based callers never carry escape sequences.
    static func truncatedByCount(
        _ text: String,
        limit: Int,
        ellipsis: String = "..."
    ) -> String {
        let boundedLimit = max(0, limit)
        guard text.count > boundedLimit else {
            return text
        }
        // The count-based contract is still an upper bound even when there is
        // insufficient room for the ellipsis. In that case preserve the prefix
        // without a marker instead of passing a negative count to `prefix`.
        guard boundedLimit >= ellipsis.count else {
            return String(text.prefix(boundedLimit))
        }
        return String(text.prefix(boundedLimit - ellipsis.count)) + ellipsis
    }

    public static func inlineText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
