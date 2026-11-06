//
//  ZenAppCommands.swift
//  ZenApp
//
//  The slash commands of an app window: the shared ones, with `/artifacts`
//  run by the window, then `/telegram`, `/voice`, and `/exit`.
//

import Foundation
import ZenCODECore

/// The slash commands of a window.
public enum ZenAppCommands {
    /// The settings enable Telegram (`telegram.isEnabled` of the settings
    /// manifest): the operator sees ``telegram``. A fact of the app, from bit
    /// 16 up, as ``ChatCommandContext`` asks of a channel's facts.
    public static let telegramEnabled = ChatCommandContext(rawValue: 1 << 16)

    /// `/exit`, which the window runs itself: it closes the window. Like the
    /// terminal's, it does not run while a prompt is generating.
    public static let exit = ChatCommandDescriptor(
        command: "/exit",
        summary: "close this window",
        help: "/exit closes this window.",
        scope: .channel
    )

    /// `/artifacts`, which the window runs itself: it shows or hides the
    /// artifacts sidebar instead of writing the artifact history in the
    /// transcript. It runs while a prompt is generating.
    public static let artifacts = ChatCommandDescriptor(
        command: "/artifacts",
        summary: "show or hide the artifacts sidebar",
        help: "/artifacts shows or hides the sidebar with the file artifacts of the session. It accepts no arguments.",
        scope: .channel,
        availableDuringGeneration: true
    )

    /// `/telegram`, which the window runs itself, as the terminal does: the
    /// status of the link, `on` hands the window's slot to the linked chat,
    /// `off` takes it back. Visible only while the settings enable Telegram
    /// (``telegramEnabled``); hidden, it answers as an unknown command. The
    /// status and `off` run while a prompt is generating; `on` does not, since
    /// the window cannot hand the ending of its own running turn to Telegram.
    public static let telegram = ChatCommandDescriptor(
        command: "/telegram",
        summary: "turn Telegram on/off",
        help: "/telegram shows Telegram status. Use /telegram on or /telegram off for this window's session.",
        scope: .channel,
        availability: telegramEnabled,
        availableDuringGeneration: true,
        generationActions: ["off"]
    )

    /// `/voice`, which the window runs through the app's voice session, as
    /// the terminal runs it: `on`, `off`, `pause`, `resume`, and bare
    /// `/voice`, which pauses or resumes. Voice mode is one for the whole
    /// app and follows the active window; the window that runs the command
    /// becomes that window first. Always visible, and it runs while a prompt
    /// is generating.
    public static let voice = ChatCommandDescriptor(
        command: "/voice",
        summary: "voice mode on/off/pause/resume",
        help: "/voice on starts voice mode with any agent in the app: utterances become prompts through local speech recognition and answers are read aloud (the app uses the system speech frameworks). Esc stops the reading. /voice off stops voice mode; /voice pause stops listening and reading aloud, /voice resume restarts both, and /voice alone toggles pause/resume. Voice mode lasts until the app quits.",
        scope: .channel,
        availableDuringGeneration: true
    )

    /// The shared commands of a window, in their order, with the shared
    /// `/artifacts` replaced in place by ``artifacts``.
    static let sharedDescriptors: [ChatCommandDescriptor] = ChatCommandRegistry.sharedDescriptors.map { descriptor in
        descriptor.command == artifacts.command ? artifacts : descriptor
    }

    /// The registry of every window: the shared commands (``artifacts`` in
    /// place of the shared `/artifacts`), then `/telegram`, `/voice`, and
    /// `/exit`.
    public static let registry = ChatCommandRegistry(
        shared: sharedDescriptors,
        channel: [(after: "", descriptors: [telegram, voice, exit])]
    )

    /// Every command of ``registry``, in display order, hidden ones included.
    public static let descriptors: [ChatCommandDescriptor] = sharedDescriptors + [telegram, voice, exit]

    /// The commands the operator sees in `context`, in display order.
    public static func visibleDescriptors(in context: ChatCommandContext) -> [ChatCommandDescriptor] {
        descriptors.filter { context.isSuperset(of: $0.availability) }
    }

    /// The context of a session whose selected agent is `agent`:
    /// `.builderAgent` for the Builder, and ``telegramEnabled`` when
    /// `telegramConfigured`; otherwise empty.
    public static func context(for agent: AgentProfile?, telegramConfigured: Bool = false) -> ChatCommandContext {
        var context: ChatCommandContext = AgentProfileStore.isBuilderAgent(agent) ? .builderAgent : []
        if telegramConfigured {
            context.insert(telegramEnabled)
        }
        return context
    }

    /// Whether the settings enable Telegram, read from the settings manifest
    /// at each call, as the terminal and ACP read it.
    static func isTelegramConfigured() -> Bool {
        AgentSettingsManifestStore.load()?.telegram?.isEnabled == true
    }

    /// The commands after which the model, thinking level, agent, and command
    /// context of the next turn are read again: the selections and the
    /// session operations.
    public static let statusFactCommands: Set<String> = [
        "/models", "/think", "/agents", "/tools", "/skills", "/sessions",
    ]

    /// `true` when `line` runs one of ``statusFactCommands`` (the `/session`
    /// alias included).
    public static func changesStatusFacts(_ line: String) -> Bool {
        guard let command = registry.descriptor(forLine: line)?.command else { return false }
        return statusFactCommands.contains(command)
    }
}
