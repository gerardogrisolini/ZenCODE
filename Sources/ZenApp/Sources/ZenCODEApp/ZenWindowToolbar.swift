//
//  ZenWindowToolbar.swift
//  ZenApp
//
//  The glass toolbar of a window: the session's selections (model, thinking,
//  agent), its capabilities (tools, skills), its work (tasks, changes), Stop,
//  and, always last, the artifacts sidebar toggle. Every other item runs a
//  slash command; the menus a command needs arrive as pending requests and
//  open as sheets.
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
}

/// The toolbar items of a window. The busy state is passed in by the owner's
/// body, so Stop follows it; the labels that show the status read it in
/// their own bodies. The artifacts sidebar toggle is always the trailing
/// item.
struct ZenWindowToolbar: ToolbarContent {
    let session: ZenWindowSession
    let isBusy: Bool

    var body: some ToolbarContent {
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
                session.run(ZenSessionCommand.agents)
            } label: {
                ZenAgentToolbarLabel(session: session)
            }
            .help("Choose the agent (/agents)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.run(ZenSessionCommand.tools)
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .help("Choose the tools (/tools)")

            Button {
                session.run(ZenSessionCommand.skills)
            } label: {
                Label("Skills", systemImage: "sparkles")
            }
            .help("Choose the skills (/skills)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.run(ZenSessionCommand.tasks)
            } label: {
                Label("Tasks", systemImage: "checklist")
            }
            .help("Show the task graph (/tasks)")

            Menu {
                ZenChangesMenuItems(session: session)
            } label: {
                Label("Changes", systemImage: "plusminus")
            }
            .help("File changes, undo, artifacts and review")
        }

        if isBusy {
            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop the turn (Esc, ⌘.)")
            }
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

/// The label of the model button: the model's display name. It reads the
/// status in its own body.
struct ZenModelToolbarLabel: View {
    let session: ZenWindowSession

    var body: some View {
        Label(ZenWindowToolbar.modelTitle(session.status.modelID), systemImage: "cpu")
            .labelStyle(.titleAndIcon)
    }
}

/// The label of the thinking button, with the current level as its help. It
/// reads the status in its own body.
struct ZenThinkingToolbarLabel: View {
    let session: ZenWindowSession

    var body: some View {
        Label("Thinking", systemImage: "brain")
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
/// The artifacts item shows or hides the artifacts sidebar, titled after
/// whether it shows; every other item runs its slash command.
struct ZenChangesMenuItems: View {
    let session: ZenWindowSession?

    var body: some View {
        Button("Show Changes") { session?.run(ZenSessionCommand.changes) }
        Button("Show Changes with Diff") { session?.run(ZenSessionCommand.changesDiff) }
        Divider()
        Button("Undo Changes") { session?.run(ZenSessionCommand.undo) }
        Divider()
        Button(session?.isArtifactsSidebarPresented == true ? "Hide Artifacts" : "Show Artifacts") {
            session?.toggleArtifactsSidebar()
        }
        Button("Review Changes") { session?.run(ZenSessionCommand.review) }
    }
}
