//
//  ZenCODEApp.swift
//  ZenApp
//
//  The entry point of the ZenCODE app: one window group whose value is the
//  workspace folder of the window, the Worktree window of a `--worktree`
//  launch, and the menu bar commands.
//

import AppKit
import Foundation
import SwiftUI

/// The SwiftUI app. The application delegate owns the launcher of the
/// runtime, so the runtime outlives every window and shuts down when the app
/// quits.
@main
struct ZenCODEApp: App {
    @NSApplicationDelegateAdaptor(ZenAppDelegate.self) private var appDelegate

    var body: some Scene {
        // The value is the workspace folder of the window; `nil` (the first
        // window, File > New Window) is the directory the app started from.
        WindowGroup("ZenCODE", for: URL.self) { $workspace in
            ZenWindowScene(launcher: appDelegate.launcher, requestedWorkspace: workspace)
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            ZenMenuCommands()
        }
        // Asks how to close the worktree of a `--worktree` launch before the
        // app quits; it opens only when asked. The app quits while it is
        // open, so it is never restored at the next launch, and it adds no
        // item to the Window menu.
        Window("Worktree", id: ZenWorktreeClosureWindow.id) {
            ZenWorktreeClosureWindow(launcher: appDelegate.launcher)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}
