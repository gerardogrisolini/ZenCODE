//
//  ToolMutationClassifier.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Classifies tool names by whether they change files, so the terminal can
/// show the source of a change and refresh the git summary after it.
enum ToolMutationClassifier {
    static func isFileMutationTool(_ toolName: String) -> Bool {
        switch normalizedMutationToolName(toolName) {
        case "local.writeFile", "local.append", "local.replace",
             "local.editFile", "local.multiEdit", "local.applyPatch",
             "local.delete", "local.move", "local.mkdir":
            return true
        default:
            return false
        }
    }

    static func normalizedMutationToolName(_ toolName: String) -> String {
        toolName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
