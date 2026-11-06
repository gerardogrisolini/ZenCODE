//
//  ZenWindowToolbar.swift
//  ZenApp
//
//  The glass toolbar of a window: the agent, the session's other selections
//  (model, thinking), its capabilities and its work (tools, skills, tasks,
//  changes) in one group, and, always last, the artifacts sidebar toggle.
//  Every other item runs a slash command; the menus a command needs arrive as
//  pending requests and open as sheets.
//

import Foundation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenCODECore

/// The commands of the toolbar and of the Session menu.
enum ZenSessionCommand {
    static let models = "/models"
    static let thinking = "/think"
    static let agents = "/agents"
    static let tools = "/tools"
    static let skills = "/skills"
    static let tasks = "/tasks"
    static let changes = "/changes"
    static let changesDiff = "/changes diff"
    static let undo = "/undo"
    static let review = "/review"
    static let help = "/help"
    static let voiceOn = "/voice on"
    static let voiceOff = "/voice off"
    static let voicePause = "/voice pause"
    static let voiceResume = "/voice resume"
}

/// The toolbar items of a window. The labels that show the status read it in
/// their own bodies. The agent comes first, with its name; the model and
/// thinking buttons follow as icons only, with the tools, skills, tasks, and
/// changes, in one group. The artifacts sidebar toggle is always the trailing
/// item.
struct ZenWindowToolbar: ToolbarContent {
    let session: ZenWindowSession

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                session.run(ZenSessionCommand.agents)
            } label: {
                ZenAgentToolbarLabel(session: session)
            }
            .help("Choose the agent (/agents)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.run(ZenSessionCommand.models)
            } label: {
                ZenModelToolbarLabel(session: session)
            }
            .help("Choose the model (/models)")

            Button {
                session.run(ZenSessionCommand.thinking)
            } label: {
                ZenThinkingToolbarLabel(session: session)
            }

            Button {
                session.run(ZenSessionCommand.tools)
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .help("Tools (/tools)")

            Button {
                session.run(ZenSessionCommand.skills)
            } label: {
                Label("Skills", systemImage: "sparkles")
            }
            .help("Skills (/skills)")

            Button {
                session.run(ZenSessionCommand.tasks)
            } label: {
                Label("Tasks", systemImage: "checklist")
            }
            .help("Tasks (/tasks)")

            Menu {
                ZenChangesMenuItems(session: session)
            } label: {
                Label("Changes", systemImage: "plusminus")
            }
            .help("Changes (/changes)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            ZenArtifactsToolbarButton(session: session)
        }
    }

    /// The model's display name, or "Model" without one.
    static func modelTitle(_ modelID: String?) -> String {
        guard let modelID, !modelID.isEmpty else { return "Model" }
        return ZenStatusFormatting.modelDisplayName(modelID)
    }

    static func thinkingHelp(_ status: ZenWindowStatus) -> String {
        guard let thinking = status.thinking else { return "Choose the thinking level (/think)" }
        return "Thinking: \(thinking.displayTitle) (/think)"
    }
}

/// The label of the model button: the `cpu` icon only. The model's display
/// name stays its title, for accessibility, but does not show. It reads the
/// status in its own body.
struct ZenModelToolbarLabel: View {
    let session: ZenWindowSession

    var body: some View {
        Label(ZenWindowToolbar.modelTitle(session.status.modelID), systemImage: "cpu")
            .labelStyle(.iconOnly)
    }
}

/// The label of the thinking button: the `brain` icon only, with the current
/// level as its help. It reads the status in its own body.
struct ZenThinkingToolbarLabel: View {
    let session: ZenWindowSession

    var body: some View {
        Label("Thinking", systemImage: "brain")
            .labelStyle(.iconOnly)
            .help(ZenWindowToolbar.thinkingHelp(session.status))
    }
}

/// The label of the agent button: the agent's name. It reads the status in
/// its own body.
struct ZenAgentToolbarLabel: View {
    let session: ZenWindowSession

    var body: some View {
        Label(session.status.agentName ?? "Agent", systemImage: "person.crop.circle")
            .labelStyle(.titleAndIcon)
    }
}

/// The items of the Changes menu, shared by the toolbar and the Session menu.
/// Every item runs its slash command.
struct ZenChangesMenuItems: View {
    let session: ZenWindowSession?

    var body: some View {
        Button("Show Changes") { session?.run(ZenSessionCommand.changes) }
        Button("Show Changes with Diff") { session?.run(ZenSessionCommand.changesDiff) }
        Divider()
        Button("Undo Changes") { session?.run(ZenSessionCommand.undo) }
        Divider()
        Button("Review Changes") { session?.run(ZenSessionCommand.review) }
    }
}
