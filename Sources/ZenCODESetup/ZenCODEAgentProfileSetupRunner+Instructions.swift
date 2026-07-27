//
//  ZenCODEAgentProfileSetupRunner+Instructions.swift
//  ZenCODE
//

import Dispatch
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
        let editorName = instructionEditorDisplayName()
        let editorCommand = instructionEditorCommand()
        let editItem = TerminalCheckboxMenuItem(
            value: AgentInstructionsEditChoice.editInEditor,
            title: hasExistingInstructions ? "Edit in \(editorName)" : "Enter in \(editorName)",
            detail: "opens a temporary text file with \(editorCommand.displayText)"
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
        #if os(macOS)
        // `open -W -t` waits for TextEdit to quit and reuses the default text
        // editor, which is the macOS-native way to edit a temp file.
        return AgentInstructionEditorCommand(
            executable: "/usr/bin/open",
            arguments: ["-W", "-t"]
        )
        #else
        // Linux has no `open -t`. Resolve the editor from the environment, the
        // way other CLI tools do: $VISUAL first, then $EDITOR, then `vi`. The
        // value may carry arguments (e.g. "code --wait"), so split executable
        // and arguments apart.
        let rawEditor = ProcessInfo.processInfo.environment["VISUAL"]?.nilIfBlank
            ?? ProcessInfo.processInfo.environment["EDITOR"]?.nilIfBlank
            ?? "vi"
        let parts = rawEditor.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        return AgentInstructionEditorCommand(
            executable: parts.first ?? "vi",
            arguments: Array(parts.dropFirst())
        )
        #endif
    }

    /// User-facing label for the editor that ``instructionEditorCommand`` will
    /// launch ("TextEdit" on macOS, the resolved $VISUAL/$EDITOR on Linux).
    static func instructionEditorDisplayName() -> String {
        #if os(macOS)
        return "TextEdit"
        #else
        let command = instructionEditorCommand()
        return command.arguments.isEmpty ? command.executable : command.displayText
        #endif
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

        let exitSignal = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: editorCommand.executable)
        process.arguments = editorCommand.arguments + [fileURL.path]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        // Assign the termination handler before run() so a process that exits
        // immediately (or that was already terminated) is still observed.
        process.terminationHandler = { _ in
            exitSignal.signal()
        }
        do {
            try process.run()
        } catch {
            throw ZenCODEAgentProfileSetupError.instructionEditorLaunchFailed(
                editorCommand.displayText,
                error.localizedDescription
            )
        }
        try awaitEditorExit(process, exitSignal: exitSignal)
        guard process.terminationStatus == 0 else {
            throw ZenCODEAgentProfileSetupError.instructionEditorFailed(
                editorCommand.displayText,
                process.terminationStatus
            )
        }

        let editedInstructions = try String(contentsOf: fileURL, encoding: .utf8)
        return editedInstructions.nilIfBlank
    }

    /// Blocks until `process` exits, but polls cooperative cancellation so an
    /// editor left open cannot hold the setup run forever.
    ///
    /// `Process.waitUntilExit()` would block the cooperative worker that runs
    /// the (otherwise synchronous) agent setup flow indefinitely. Instead the
    /// termination handler (assigned by the caller before `run()`) signals
    /// `exitSignal`; if the surrounding task is cancelled, the editor is
    /// terminated and the wait unwinds with `CancellationError`. The synchronous
    /// public setup entry points are preserved, so this stays a blocking call
    /// that is at least interruptible.
    static func awaitEditorExit(
        _ process: Process,
        exitSignal: DispatchSemaphore
    ) throws {
        while exitSignal.wait(timeout: .now() + .milliseconds(100)) != .success {
            if Task.isCancelled {
                process.terminate()
                // Drain the signal once the termination handler fires so the
                // semaphore is not left counting against a later caller.
                _ = exitSignal.wait(timeout: .now() + .seconds(2))
                throw CancellationError()
            }
        }
    }

}
