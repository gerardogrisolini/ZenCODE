//
//  ZenCODEAgentProfileSetupRunner+Instructions.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

extension ZenCODEAgentProfileSetupRunner {
    static func promptInstructions(defaultValue: String?) throws -> String? {
        if let currentInstructions = defaultValue?.nilIfBlank {
            AgentOutput.standardError.writeString(
                """

                Current agent instructions:
                ---
                \(currentInstructions)
                ---

                """
            )

            let choice = TerminalCheckboxMenu.selectOne(
                title: "Agent instructions",
                items: instructionEditChoiceItems(hasExistingInstructions: true),
                selected: AgentInstructionsEditChoice.keep
            ) ?? .keep

            switch choice {
            case .keep:
                return defaultValue
            case .editInEditor:
                return try editInstructionsInEditor(defaultValue: defaultValue)
            }
        }

        return try editInstructionsInEditor(defaultValue: defaultValue)
    }

    static func instructionEditChoiceItems(
        hasExistingInstructions: Bool
    ) -> [TerminalCheckboxMenuItem<AgentInstructionsEditChoice>] {
        let editItem = TerminalCheckboxMenuItem(
            value: AgentInstructionsEditChoice.editInEditor,
            title: hasExistingInstructions ? "Edit in TextEdit" : "Enter in TextEdit",
            detail: "opens a temporary text file with /usr/bin/open -W -t"
        )
        guard hasExistingInstructions else {
            return [editItem]
        }
        return [
            TerminalCheckboxMenuItem(
                value: .keep,
                title: "Keep current instructions",
                detail: "leave the existing instructions unchanged"
            ),
            editItem
        ]
    }

    static func instructionEditorCommand() -> AgentInstructionEditorCommand {
        AgentInstructionEditorCommand(
            executable: "/usr/bin/open",
            arguments: ["-W", "-t"]
        )
    }

    static func editInstructionsInEditor(defaultValue: String?) throws -> String? {
        let editorCommand = instructionEditorCommand()
        let fileManager = FileManager.default
        let fileURL = fileManager.temporaryDirectory
            .appendingPathComponent("ZenCODE-agent-instructions-\(UUID().uuidString).md")
        try (defaultValue ?? "").write(to: fileURL, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: fileURL)
        }

        AgentOutput.standardError.writeString(
            "Opening \(editorCommand.displayText). Save and close the editor to continue.\n"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: editorCommand.executable)
        process.arguments = editorCommand.arguments + [fileURL.path]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw ZenCODEAgentProfileSetupError.instructionEditorLaunchFailed(
                editorCommand.displayText,
                error.localizedDescription
            )
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ZenCODEAgentProfileSetupError.instructionEditorFailed(
                editorCommand.displayText,
                process.terminationStatus
            )
        }

        let editedInstructions = try String(contentsOf: fileURL, encoding: .utf8)
        return editedInstructions.nilIfBlank
    }

}
