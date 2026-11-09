//
//  ChatSessionController+WorkspaceAccess.swift
//  ZenCODE
//
//  The workspace-folder access request that follows an agent or tool
//  selection.
//

import Foundation

extension ChatSessionController {
    // MARK: - Workspace access

    /// Asks the host to let the selected tools reach the workspace folder.
    /// When it refuses, the tools that need the folder are deselected and
    /// ``ChatSessionNotice/workspaceAccessDenied(_:)`` is presented.
    public func ensureWorkspaceAccess() async {
        if await requestWorkspaceAccessIfNeeded() {
            await presentSessionStateChanged()
        }
    }

    /// Returns `true` when access was refused and tools were deselected.
    func requestWorkspaceAccessIfNeeded() async -> Bool {
        let items = await toolSelectionItems()
        let workspaceSelectionKeys = TerminalToolSelectionCatalog.workspaceAccessSelectionKeys(
            for: selection.toolKeys,
            items: items
        )
        guard !workspaceSelectionKeys.isEmpty else {
            return false
        }

        let request = ChatWorkspaceAccessRequest(
            workspaceURL: workingDirectory,
            toolTitles: items
                .filter { workspaceSelectionKeys.contains($0.key) }
                .map(\.title)
        )
        guard !(await host.requestWorkspaceAccess(request)) else {
            return false
        }

        selection.toolKeys.subtract(workspaceSelectionKeys)
        await effectivePresenter(for: nil).presentSessionNotice(.workspaceAccessDenied(request))
        return true
    }
}
