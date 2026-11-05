//
//  ZenAppCommands.swift
//  ZenApp
//
//  The slash commands of an app window: the shared ones, with `/artifacts`
//  run by the window, and `/exit`.
//

import Foundation
import ZenCODECore

/// The slash commands of a window.
public enum ZenAppCommands {
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

    /// The shared commands of a window, in their order, with the shared
    /// `/artifacts` replaced in place by ``artifacts``.
    static let sharedDescriptors: [ChatCommandDescriptor] = ChatCommandRegistry.sharedDescriptors.map { descriptor in
        descriptor.command == artifacts.command ? artifacts : descriptor
    }

    /// The registry of every window: the shared commands (``artifacts`` in
    /// place of the shared `/artifacts`), then `/exit`.
    public static let registry = ChatCommandRegistry(
        shared: sharedDescriptors,
        channel: [(after: "", descriptors: [exit])]
    )

    /// Every command of ``registry``, in display order, hidden ones included.
    public static let descriptors: [ChatCommandDescriptor] = sharedDescriptors + [exit]

    /// The commands the operator sees in `context`, in display order.
    public static func visibleDescriptors(in context: ChatCommandContext) -> [ChatCommandDescriptor] {
        descriptors.filter { context.isSuperset(of: $0.availability) }
    }

    /// The context of a session whose selected agent is `agent`:
    /// `.builderAgent` for the Builder, otherwise empty.
    public static func context(for agent: AgentProfile?) -> ChatCommandContext {
        AgentProfileStore.isBuilderAgent(agent) ? .builderAgent : []
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
