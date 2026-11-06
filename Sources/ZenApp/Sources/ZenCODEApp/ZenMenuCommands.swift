//
//  ZenMenuCommands.swift
//  ZenApp
//
//  The menu bar of the app: Open Folder, New and Save Session in the File
//  menu, and the Session menu, acting on the session of the key window; its
//  Show/Hide Chat Reader item (⌃Y) opens and closes the shared-chat reader,
//  its Full Access item (⌃G) switches the app's access mode, and its Voice
//  Mode and Pause/Resume Voice items run `/voice`.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppSession
import ZenCODECore

/// The menu bar commands. They act on the session the key window publishes
/// (``FocusedValues/zenWindowSession``) and are disabled without one.
///
/// Show/Hide Chat Reader (⌃Y) is titled after what a click does
/// (``ZenSharedChatPanelLogic/menuTitle(isReaderOpen:selectedTab:)``). As a
/// menu key equivalent, ⌃Y reaches it before the focused composer, whose text
/// view would read it as the emacs yank.
///
/// Full Access (⌃G) is checked while the app's runner runs `local.exec` and
/// the destructive tools without asking (``ZenWindowSession/isFullAccess``);
/// it switches the mode for every window, as the terminal's Ctrl+G, also
/// while a turn generates. As a menu key equivalent, ⌃G reaches it before
/// the focused composer's text view, like ⌃Y.
///
/// Voice Mode is checked while the app's voice mode is on
/// (``ZenWindowSession/voiceState``, one for every window) and runs
/// `/voice on` or `/voice off`; Pause Voice / Resume Voice, titled after
/// what a click does and enabled only while voice mode is on, runs
/// `/voice pause` or `/voice resume`. Like the items below them they run
/// the command in the key window, with its conversation selected first
/// (``ZenWindowSession/run(_:)``), and have no shortcut.
struct ZenMenuCommands: Commands {
    @FocusedValue(\.zenWindowSession) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") {
                openFolder()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("New Session") {
                session?.startNewSession()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(session == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Session") {
                session?.saveSession()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(session == nil)
        }

        CommandMenu("Session") {
            Button("Stop") {
                session?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(session == nil)

            Divider()

            Button(ZenSharedChatPanelLogic.menuTitle(
                isReaderOpen: session?.isSharedChatReaderOpen == true,
                selectedTab: session?.selectedTab ?? .chat
            )) {
                session?.toggleSharedChatReader()
            }
            .keyboardShortcut("y", modifiers: .control)
            .disabled(session == nil)

            Divider()

            Toggle("Full Access", isOn: Binding(
                get: { session?.isFullAccess == true },
                set: { _ in session?.toggleFullAccess() }
            ))
            .keyboardShortcut("g", modifiers: .control)
            .disabled(session == nil)

            Divider()

            Toggle("Voice Mode", isOn: Binding(
                get: { session?.voiceState.isOn == true },
                set: { isOn in
                    session?.run(isOn ? ZenSessionCommand.voiceOn : ZenSessionCommand.voiceOff)
                }
            ))
            .disabled(session == nil)

            Button(session?.voiceState.isPaused == true ? "Resume Voice" : "Pause Voice") {
                guard let session else { return }
                session.run(
                    session.voiceState.isPaused ? ZenSessionCommand.voiceResume : ZenSessionCommand.voicePause
                )
            }
            .disabled(session?.voiceState.isOn != true)

            Divider()

            Group {
                Button("Agents…") { session?.run(ZenSessionCommand.agents) }

                Divider()

                Button("Models…") { session?.run(ZenSessionCommand.models) }
                Button("Thinking…") { session?.run(ZenSessionCommand.thinking) }

                Divider()

                Button("Tools…") { session?.run(ZenSessionCommand.tools) }
                Button("Skills…") { session?.run(ZenSessionCommand.skills) }

                Divider()

                Button("Tasks") { session?.run(ZenSessionCommand.tasks) }
                Button("Changes") { session?.run(ZenSessionCommand.changes) }
                Button("Undo Changes") { session?.run(ZenSessionCommand.undo) }

                Divider()

                Button("Help") { session?.run(ZenSessionCommand.help) }
            }
            .disabled(session == nil)
        }
    }

    /// Asks for a folder and opens a window on it (or brings forward the
    /// window already open on it).
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose the workspace folder of the new window."
        if let workspace = session?.workspace {
            panel.directoryURL = workspace
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: url.standardizedFileURL)
    }
}
