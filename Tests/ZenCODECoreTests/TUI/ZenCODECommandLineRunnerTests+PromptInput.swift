//
//  ZenCODECommandLineRunnerTests+PromptInput.swift
//  ZenCODE
//
//  Tests for the headless prompt input: piped context, prompt files and their
//  failure classification, with the pipe and temporary directory helpers they
//  use.
//

import Foundation
@testable import ZenCODECore
import Synchronization
import Testing
import ToolCore

extension ZenCODECommandLineRunnerTests {
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

    @Test
    func headlessPromptWithoutInlineOrFileFailsBeforeReadingStdin() throws {
        let stdin = try pipe(containing: "build log")
        #expect(throws: ZenCODEHeadlessRunnerError.self) {
            try ZenCODEHeadlessRunner.prompt(
                inlinePrompt: nil,
                promptFile: nil,
                stdin: stdin,
                stdinIsTerminal: false
            )
        }
        #expect(String(decoding: stdin.readDataToEndOfFile(), as: UTF8.self) == "build log")
    }

    @Test
    func headlessPromptAddsPipedContextAfterTheFile() throws {
        try withPromptDirectory { directory in
            let path = try writePromptFile("summarize\n", in: directory)
            #expect(
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: nil,
                    promptFile: path,
                    stdin: pipe(containing: "build log\n"),
                    stdinIsTerminal: false
                ) == "summarize\n\nAdditional context from stdin:\nbuild log"
            )
            #expect(
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: "explain",
                    promptFile: path,
                    stdin: pipe(containing: "build log\n"),
                    stdinIsTerminal: false
                ) == "explain\n\nAdditional context from file:\nsummarize\n\nAdditional context from stdin:\nbuild log"
            )
        }
    }

    @Test
    func headlessPromptReportsPromptFileFailuresBeforeReadingStdin() throws {
        try withPromptDirectory { directory in
            let missing = directory.appendingPathComponent("missing.md").path
            let stdin = try pipe(containing: "build log")
            #expect(throws: ZenCODEPromptFileError.unreadable(path: missing)) {
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: "explain",
                    promptFile: missing,
                    stdin: stdin,
                    stdinIsTerminal: false
                )
            }
            #expect(String(decoding: stdin.readDataToEndOfFile(), as: UTF8.self) == "build log")

            #expect(throws: ZenCODEPromptFileError.unreadable(path: directory.path)) {
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: nil,
                    promptFile: directory.path,
                    stdinIsTerminal: true
                )
            }
            #expect(throws: ZenCODEPromptFileError.notAbsolute(path: "prompt.md")) {
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: "explain",
                    promptFile: "prompt.md",
                    stdinIsTerminal: true
                )
            }
        }
    }

    @Test
    func promptFileReaderClassifiesEveryFailure() throws {
        #expect(ZenCODEPromptFile.isAbsolutePath("/tmp/prompt.md"))
        #expect(!ZenCODEPromptFile.isAbsolutePath("prompt.md"))
        #expect(!ZenCODEPromptFile.isAbsolutePath("~/prompt.md"))
        #expect(!ZenCODEPromptFile.isAbsolutePath(""))

        try withPromptDirectory { directory in
            let missing = directory.appendingPathComponent("missing.md").path
            #expect(throws: ZenCODEPromptFileError.unreadable(path: missing)) {
                try ZenCODEPromptFile.read(path: missing)
            }
            #expect(throws: ZenCODEPromptFileError.unreadable(path: directory.path)) {
                try ZenCODEPromptFile.read(path: directory.path)
            }
            #expect(throws: ZenCODEPromptFileError.notAbsolute(path: "relative.md")) {
                try ZenCODEPromptFile.read(path: "relative.md")
            }

            let empty = try writePromptFile("", named: "empty.md", in: directory)
            #expect(throws: ZenCODEPromptFileError.empty(path: empty)) {
                try ZenCODEPromptFile.read(path: empty)
            }
            let blank = try writePromptFile(" \n\t\r\n ", named: "blank.md", in: directory)
            #expect(throws: ZenCODEPromptFileError.empty(path: blank)) {
                try ZenCODEPromptFile.read(path: blank)
            }

            let binary = directory.appendingPathComponent("binary.bin")
            try Data([0xFF, 0xFE, 0x41, 0x80]).write(to: binary)
            #expect(throws: ZenCODEPromptFileError.notUTF8(path: binary.path)) {
                try ZenCODEPromptFile.read(path: binary.path)
            }

            let accented = try writePromptFile("\n  Riassumi le modifiche: è già così ✓\n", named: "utf8.md", in: directory)
            #expect(try ZenCODEPromptFile.read(path: accented) == "Riassumi le modifiche: è già così ✓")
        }
    }

    @Test
    func jsonlPromptFileErrorsAreGenericAndNeverCarryThePath() throws {
        let path = "/Users/alice/.secrets/prompt.md"
        let errors: [ZenCODEPromptFileError] = [
            .notAbsolute(path: path),
            .unreadable(path: path),
            .notUTF8(path: path),
            .empty(path: path)
        ]
        for error in errors {
            let publicError = ZenCODEHeadlessJSONLProtocol.publicError(for: error)
            #expect(publicError.category == .configuration)
            #expect(
                publicError.publicMessage
                    == ZenCODEHeadlessJSONLProtocol.PublicErrorMessages.invalidPromptFile
            )
            #expect(!publicError.publicMessage.contains(path))

            let record = ZenCODEHeadlessJSONLProtocol.error(runID: "prompt-file", error)
            let encoded = String(
                decoding: try ZenCODEHeadlessJSONLProtocol.encoded(record),
                as: UTF8.self
            )
            #expect(!encoded.contains(path))
            #expect(!encoded.contains("secrets"))
            #expect(record.objectValue?["category"]?.stringValue == "configuration")
            #expect(
                record.objectValue?["message"]?.stringValue
                    == "The prompt file is missing, unreadable, empty, or not UTF-8 text."
            )
        }

        let noPrompt = ZenCODEHeadlessJSONLProtocol.publicError(for: ZenCODEHeadlessRunnerError.noPrompt)
        #expect(noPrompt.publicMessage == "No prompt provided. Pass text after -p/--prompt.")
        let missingFileValue = ZenCODEHeadlessJSONLProtocol.publicError(
            for: AgentConfigurationError.missingValue("-f")
        )
        #expect(missingFileValue.category == .configuration)
        #expect(missingFileValue.publicMessage == "Invalid command-line arguments.")
    }

    /// Runs `body` with a fresh UUID-named directory, removed afterwards.
    private func withPromptDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-prompt-file-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writePromptFile(
        _ text: String,
        named name: String = "prompt.md",
        in directory: URL
    ) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func pipe(containing text: String) throws -> FileHandle {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        return pipe.fileHandleForReading
    }
}
