//
//  ZenComposerPreviews.swift
//  ZenApp
//
//  The Xcode previews of the composer and the sample values of the controls'
//  previews.
//

import SwiftUI
import ZenCODECore

#Preview("Composer – idle") {
    @Previewable @State var draft = ""
    ZenComposer(
        draft: $draft,
        isBusy: false,
        commands: ZenControlsPreviewData.commands
    )
    .padding()
    .frame(width: 640)
}

#Preview("Composer – suggestions") {
    @Previewable @State var draft = "/s"
    ZenComposer(
        draft: $draft,
        isBusy: false,
        commands: ZenControlsPreviewData.commands,
        monospaced: true
    )
    .padding()
    .frame(width: 640, height: 320, alignment: .bottom)
}

#Preview("Composer – mentions") {
    @Previewable @State var draft = "@"
    ZenComposer(
        draft: $draft,
        isBusy: false,
        commands: ZenControlsPreviewData.commands,
        mentions: ZenControlsPreviewData.mentions,
        monospaced: true
    )
    .padding()
    .frame(width: 640, height: 320, alignment: .bottom)
}

#Preview("Composer – busy with queue") {
    @Previewable @State var draft = "And then run the tests"
    ZenComposer(
        draft: $draft,
        isBusy: true,
        commands: ZenControlsPreviewData.commands,
        queued: [
            ZenComposerQueuedItem(text: "Refactor the status bar formatting"),
            ZenComposerQueuedItem(text: "Write the\nchangelog entry")
        ]
    )
    .padding()
    .frame(width: 640)
}

/// Sample values of the previews.
enum ZenControlsPreviewData {
    static let commands: [ChatCommandDescriptor] = [
        ChatCommandDescriptor(command: "/help", summary: "show the commands", help: "/help"),
        ChatCommandDescriptor(command: "/sessions", summary: "manage saved sessions", help: "/sessions"),
        ChatCommandDescriptor(command: "/skills", summary: "select skills", help: "/skills"),
        ChatCommandDescriptor(
            command: "/save",
            summary: "save the session as",
            help: "/save <name>",
            requiresArgument: true
        ),
        ChatCommandDescriptor(command: "/models", summary: "choose the model", help: "/models")
    ]

    static let mentions: [SharedChatMentionParser.Suggestion] = [
        SharedChatMentionParser.Suggestion(handle: "coordinator", target: .coordinator),
        SharedChatMentionParser.Suggestion(handle: "all", target: .all),
        SharedChatMentionParser.Suggestion(handle: "reviewer", target: .agent(name: "Reviewer")),
        SharedChatMentionParser.Suggestion(handle: "builder-2", target: .agent(name: "Builder"))
    ]

    static let items: [ChatChoiceItem] = [
        ChatChoiceItem(id: "a", title: "Qwen3-Coder-30B", detail: "local · 4bit", group: "MLX", isCurrent: true),
        ChatChoiceItem(id: "b", title: "Devstral-Small", detail: "local · 8bit", group: "MLX"),
        ChatChoiceItem(id: "c", title: "gpt-5", detail: "subscription", group: "OpenAI"),
        ChatChoiceItem(id: "d", title: "gpt-5-mini", group: "OpenAI")
    ]
}
