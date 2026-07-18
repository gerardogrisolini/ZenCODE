//
//  TerminalChat+TextRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    public func writeDiagnostic(_ message: String) async {
        if message.hasPrefix("Generation done:") {
            if !didReceiveMetricsForCurrentPrompt {
                await writeChatError("\n\n[ZenCODE] \(compactGenerationSummary(message))\n")
            }
            return
        }

        guard !message.hasPrefix("Remote request:") else {
            return
        }

        await writeChatError("\u{1B}[90m[ZenCODE] \(message)\u{1B}[0m\n")
    }

    public func writeThought(_ delta: String) async {
        await renderCoordinator.writeThought(delta)
    }

    public func writeAssistantContent(_ delta: String) async {
        await renderCoordinator.writeAssistantContent(delta)
    }

    public func finishAssistantContentFormatting() async {
        await renderCoordinator.finishAssistantContent()
    }

    public func writeSubmittedPrompt(_ prompt: String) async {
        await renderCoordinator.writeSubmittedPrompt(prompt)
    }

    public func finishThoughtOutputIfNeeded() async {
        await renderCoordinator.finishThoughtOutput()
    }

    func finishStreamingOutput() async {
        await renderCoordinator.finishStreamingOutput()
    }

    func writeChatOutput(_ text: String, preservesSpacing: Bool = false) async {
        await renderCoordinator.writeOutput(text, preservesSpacing: preservesSpacing)
    }

    func flushChatOutput() async {
        await renderCoordinator.flushOutput()
    }

    func writeChatError(_ text: String, preservesSpacing: Bool = false) async {
        await renderCoordinator.writeError(text, preservesSpacing: preservesSpacing)
    }

    func writeFailureMessage(_ text: String) async {
        await renderCoordinator.writeFailureMessage(text)
    }

    func writeSystemMessage(_ text: String) async {
        await renderCoordinator.writeSystemMessage(text)
    }

    /// Renders a complete, non-streaming Markdown block through the same
    /// terminal formatter used for assistant responses. A dedicated formatter
    /// keeps command output from sharing buffered streaming state.
    func writeMarkdownMessage(_ markdown: String) async {
        await renderCoordinator.writeMarkdownMessage(markdown)
    }

    func writeFileChangeSummaryMessage(_ text: String) async {
        await renderCoordinator.writeFileChangeSummaryMessage(text)
    }

    func writeOperationalMessage(_ text: String) async {
        await renderCoordinator.writeOperationalMessage(text)
    }
}
