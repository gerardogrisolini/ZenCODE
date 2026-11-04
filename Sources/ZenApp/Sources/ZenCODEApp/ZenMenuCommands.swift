//
//  ZenMenuCommands.swift
//  ZenApp
//
//  The menu bar of the app: Open Folder, New and Save Session in the File
//  menu, and the Session menu, acting on the session of the key window; its
//  Show/Hide Chat Reader item (⌃Y) opens and closes the shared-chat reader.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppSession

/// The menu bar commands. They act on the session the key window publishes
/// (``FocusedValues/zenWindowSession``) and are disabled without one.
///
/// Show/Hide Chat Reader (⌃Y) is titled after what a click does
/// (``ZenSharedChatPanelLogic/menuTitle(isReaderOpen:selectedTab:)``). As a
/// menu key equivalent, ⌃Y reaches it before the focused composer, whose text
/// view would read it as the emacs yank.
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

            Group {
                Button("Models…") { session?.run(ZenSessionCommand.models) }
                Button("Thinking…") { session?.run(ZenSessionCommand.thinking) }
                Button("Agents…") { session?.run(ZenSessionCommand.agents) }

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
