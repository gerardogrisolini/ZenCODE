//
//  ZenCODECommandLineRunnerTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ZenCODECommandLineRunnerTests {
    @Test
    func recognizedCommandLineOptionsStillRouteToTheCommandLine() {
        let bundleExecutable = "/Applications/ZenCODE.app/Contents/MacOS/ZenCODE"
        for option in ["--version", "--doctor", "--acp", "-p", "--prompt", "--model", "--max-tool-rounds"] {
            #expect(
                ZenCODECommandLineRunner.shouldRunAsCommandLine(
                    arguments: [bundleExecutable, option]
                )
            )
        }
    }

    @Test
    func headlessArgumentAcceptsInlinePrompt() throws {
        try AgentConfiguration.validateArguments(["zen", "-p", "summarize this"])
        try AgentConfiguration.validateArguments(["zen", "--prompt", "summarize this"])
    }

    @Test
    func headlessArgumentRequiresAValueAndRejectsACP() {
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "-p"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "-p", "--model", "example/model"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "-p", "-"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "--acp", "-p", "hello"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "-p", "hello", "--acp"])
        }
    }

    @Test
    func headlessPromptUsesPipedContext() throws {
        #expect(
            try ZenCODEHeadlessRunner.prompt(
                inlinePrompt: "explain",
                stdin: pipe(containing: "build log\n"),
                stdinIsTerminal: false
            ) == "explain\n\nAdditional context from stdin:\nbuild log"
        )
        #expect(
            try ZenCODEHeadlessRunner.prompt(
                inlinePrompt: "explain",
                stdin: pipe(containing: "ignored"),
                stdinIsTerminal: true
            ) == "explain"
        )
    }

    private func pipe(containing text: String) throws -> FileHandle {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        return pipe.fileHandleForReading
    }
}
