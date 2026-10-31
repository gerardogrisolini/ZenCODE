//
//  ChatWorkspaceCommandsTests.swift
//  ZenCODE
//
//  The workspace commands of the shared controller (`/changes`, `/undo`,
//  `/artifacts`, `/open`, `/attach`) against a scripted host and a recording
//  presenter. Every test runs in a support directory, a working directory,
//  and (when it needs one) a home folder named by UUIDs; the host records
//  what it is asked to open or pick and never opens a file, a URL, or a
//  picker.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Chat workspace commands", .serialized)
struct ChatWorkspaceCommandsTests {
    // MARK: - Fixtures

    /// One modified file whose snapshot `/undo` can restore.
    private static let modifiedSummary = TurnFileChangeSummary(entries: [
        .init(
            path: "Value.swift",
            additions: 1,
            deletions: 1,
            status: .modified,
            isBinary: false,
            existedBefore: true,
            beforeDataBase64: Data("let value = 1\n".utf8).base64EncodedString(),
            patch: nil
        ),
    ])

    /// An added file with its patch, which the artifact history records.
    private static let addedSummary = TurnFileChangeSummary(entries: [
        .init(
            path: "Added.swift",
            additions: 1,
            deletions: 0,
            status: .added,
            isBinary: false,
            existedBefore: false,
            beforeDataBase64: nil,
            patch: "@@ -0,0 +1,1 @@\n+let value = 1\n"
        ),
    ])

    /// An in-memory attachment: staged, listed, and never opened.
    private static func memoryAttachment(_ filename: String) -> AgentRuntimeAttachment {
        AgentRuntimeAttachment(kind: .image, data: Data([0]), originalFilename: filename)
    }

    /// Writes `contents` at `relativePath` under `directory` and returns the
    /// standardized file URL.
    @discardableResult
    private static func writeFile(
        _ relativePath: String,
        in directory: URL,
        contents: Data = Data([0])
    ) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
        return url.standardizedFileURL
    }

    /// Runs `body` with a home folder named by a UUID, removed afterwards.
    private static func withHomeDirectory(_ body: (URL) async throws -> Void) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-chat-home-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try await body(home.standardizedFileURL)
    }

    // MARK: - /changes

    @Test
    func changesPresentsTheLastSummaryAndReadsOnlyTheDiffArguments() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            for line in ["/changes", "/changes diff", "/changes --diff"] {
                #expect(await controller.runChangesCommand(line: line)
                    == ChatCommandOutcome(notices: [.noTrackedFileChanges]))
            }

            let summary = Self.modifiedSummary
            controller.lastFileChangeSummary = summary
            let lines: [(line: String, includesDiff: Bool)] = [
                ("/changes", false),
                ("/changes diff", true),
                ("/changes --diff", true),
                ("/changes DIFF", true),
                // Any other argument is ignored, as the terminal always did.
                ("/changes everything", false),
            ]
            for (line, includesDiff) in lines {
                #expect(await controller.runChangesCommand(line: line)
                    == ChatCommandOutcome(notices: [.fileChangeSummary(summary, includesDiff: includesDiff)]))
            }
            #expect(controller.lastFileChangeSummary == summary)
            // The command echoes nothing and asks nothing of the runtime.
            #expect(await harness.presenter.events.isEmpty)
            #expect(await harness.callNames().isEmpty)
        }
    }

    // MARK: - /undo

    @Test
    func undoRestoresTheLastSummaryInTheWorkingDirectory() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let edited = try Self.writeFile(
                "Value.swift",
                in: harness.workspace,
                contents: Data("let value = 2\n".utf8)
            )
            let created = try Self.writeFile("Created.swift", in: harness.workspace)
            controller.lastFileChangeSummary = TurnFileChangeSummary(
                entries: Self.modifiedSummary.entries + [
                    .init(
                        path: "Created.swift",
                        additions: 1,
                        deletions: 0,
                        status: .added,
                        isBinary: false,
                        existedBefore: false,
                        beforeDataBase64: nil,
                        patch: nil
                    ),
                ]
            )

            #expect(await controller.runUndoCommand(line: "/undo")
                == ChatCommandOutcome(notices: [.fileChangesReverted]))
            // The relative paths resolve in the controller's working directory.
            #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 1\n")
            #expect(!FileManager.default.fileExists(atPath: created.path))
            #expect(controller.lastFileChangeSummary == nil)

            #expect(await controller.runUndoCommand(line: "/undo")
                == ChatCommandOutcome(notices: [
                    .fileChangesNotUndone(description: "No tracked file changes to undo.")
                ]))
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func undoRefusesArgumentsAndReportsWhatItCannotUndo() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let edited = try Self.writeFile(
                "Value.swift",
                in: harness.workspace,
                contents: Data("let value = 2\n".utf8)
            )
            controller.lastFileChangeSummary = Self.modifiedSummary

            // `/undo` takes no arguments: the line names no command.
            #expect(await controller.runUndoCommand(line: "/undo everything")
                == ChatCommandOutcome(notices: [.unknownCommand(line: "/undo everything")]))
            #expect(ChatSessionNoticeText.text(for: .unknownCommand(line: "/undo everything"))
                == "ZenCODE: unknown command '/undo'.\n")
            #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 2\n")
            #expect(controller.lastFileChangeSummary == Self.modifiedSummary)

            // A summary without the evidence to restore it.
            let unavailable = TurnFileChangeSummary(entries: [
                .init(
                    path: "Unknown.swift",
                    additions: 1,
                    deletions: 0,
                    status: .modified,
                    isBinary: false,
                    existedBefore: nil,
                    beforeDataBase64: nil,
                    patch: nil
                ),
            ])
            controller.lastFileChangeSummary = unavailable
            #expect(await controller.runUndoCommand(line: "/undo")
                == ChatCommandOutcome(notices: [
                    .fileChangesNotUndone(description: "Undo is not available for the latest file changes.")
                ]))
            #expect(controller.lastFileChangeSummary == unavailable)

            // Restoring fails: the folder of the file is a file.
            try Self.writeFile("blocker", in: harness.workspace)
            let blocked = TurnFileChangeSummary(entries: [
                .init(
                    path: "blocker/Inner.swift",
                    additions: 1,
                    deletions: 1,
                    status: .modified,
                    isBinary: false,
                    existedBefore: true,
                    beforeDataBase64: Data("old\n".utf8).base64EncodedString(),
                    patch: nil
                ),
            ])
            controller.lastFileChangeSummary = blocked
            let outcome = await controller.runUndoCommand(line: "/undo")
            guard case let .fileChangesUndoFailed(description)? = outcome.notices.first else {
                Issue.record("Expected an undo failure, got \(outcome)")
                return
            }
            #expect(outcome.notices.count == 1)
            #expect(!description.isEmpty)
            #expect(controller.lastFileChangeSummary == blocked)
        }
    }

    // MARK: - /artifacts

    @Test
    func artifactsListTheSessionHistoryAndTakeNoArguments() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            #expect(await controller.runArtifactsCommand(line: "/artifacts")
                == ChatCommandOutcome(notices: [.noFileArtifacts]))

            await controller.fileArtifactHistory.append(
                summary: Self.addedSummary,
                sessionID: controller.sessionID,
                workingDirectory: harness.workspace
            )
            let turns = await controller.fileArtifactHistory.snapshot()
            #expect(turns.count == 1)

            #expect(await controller.runArtifactsCommand(line: "/artifacts")
                == ChatCommandOutcome(notices: [.fileArtifacts(turns)]))
            #expect(await controller.runArtifactsCommand(line: "/artifacts all")
                == ChatCommandOutcome(notices: [.artifactsTakeNoArguments]))
            // Presenting the history neither changes it nor echoes the line.
            #expect(await controller.fileArtifactHistory.snapshot() == turns)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    // MARK: - /attach

    @Test
    func attachStagesFilesFromTheWorkspaceTheHomeAndFileURLs() async throws {
        try await Self.withHomeDirectory { home in
            try await withChatHarness(userHomeDirectoryURL: home) { harness in
                let controller = harness.controller
                let photo = try Self.writeFile("photo.png", in: harness.workspace)
                let clip = try Self.writeFile("my clip.mov", in: harness.workspace)
                let logo = try Self.writeFile("pictures/logo.jpg", in: home)
                let linked = try Self.writeFile("linked.png", in: harness.workspace)

                let first = await controller.runAttachCommand(line: #"/attach photo.png "my clip.mov""#)
                let staged = controller.pendingAttachments
                #expect(staged.map(\.originalFilename) == ["photo.png", "my clip.mov"])
                #expect(staged.map(\.fileURL?.path) == [photo.path, clip.path])
                #expect(first == ChatCommandOutcome(notices: [
                    .attachmentsAdded(addedCount: 2, pendingCount: 2),
                    .pendingAttachments(staged),
                ]))

                let second = await controller.runAttachCommand(
                    line: "/attach ~/pictures/logo.jpg \(linked.absoluteString)"
                )
                let all = controller.pendingAttachments
                #expect(all.map(\.fileURL?.path) == [photo.path, clip.path, logo.path, linked.path])
                #expect(second == ChatCommandOutcome(notices: [
                    .attachmentsAdded(addedCount: 2, pendingCount: 4),
                    .pendingAttachments(all),
                ]))
                #expect(await harness.host.interactions.isEmpty)
                #expect(await harness.presenter.events.isEmpty)
            }
        }
    }

    @Test
    func attachListsAndDeletesTheStagedAttachments() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let first = Self.memoryAttachment("a.png")
            let second = Self.memoryAttachment("b.png")
            let third = Self.memoryAttachment("c.png")
            controller.pendingAttachments = [first, second, third]

            #expect(await controller.runAttachCommand(line: "/attach list")
                == ChatCommandOutcome(notices: [.pendingAttachments([first, second, third])]))
            #expect(await controller.runAttachCommand(line: "/attach delete")
                == ChatCommandOutcome(notices: [.attachmentDeleteUsage]))
            for argument in ["9", "0", "two"] {
                #expect(await controller.runAttachCommand(line: "/attach delete \(argument)")
                    == ChatCommandOutcome(notices: [.invalidAttachmentSelection(argument: argument)]))
            }
            #expect(controller.pendingAttachments == [first, second, third])

            #expect(await controller.runAttachCommand(line: "/attach delete 2")
                == ChatCommandOutcome(notices: [
                    .attachmentRemoved(filename: "b.png"),
                    .pendingAttachments([first, third]),
                ]))
            #expect(await controller.runAttachCommand(line: "/attach DELETE ALL")
                == ChatCommandOutcome(notices: [.pendingAttachmentsRemoved]))
            #expect(controller.pendingAttachments.isEmpty)

            #expect(await controller.runAttachCommand(line: "/attach delete 1")
                == ChatCommandOutcome(notices: [.noPendingAttachments]))
            #expect(await controller.runAttachCommand(line: "/attach list")
                == ChatCommandOutcome(notices: [.pendingAttachments([])]))
        }
    }

    @Test
    func attachReportsUsageQuotesAndFilesItCannotImport() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try Self.writeFile("notes.txt", in: harness.workspace, contents: Data("text".utf8))

            #expect(await controller.runAttachCommand(line: #"/attach """#)
                == ChatCommandOutcome(notices: [.attachmentUsage]))
            #expect(await controller.runAttachCommand(line: #"/attach "open.png"#)
                == ChatCommandOutcome(notices: [.unterminatedAttachmentQuote]))
            #expect(await controller.runAttachCommand(line: "/attach notes.txt")
                == ChatCommandOutcome(notices: [
                    .operationFailed(description: "Unsupported attachment type: notes.txt")
                ]))
            #expect(await controller.runAttachCommand(line: "/attach missing.png")
                == ChatCommandOutcome(notices: [
                    .operationFailed(description: "Unable to read attachment data from missing.png.")
                ]))
            #expect(controller.pendingAttachments.isEmpty)
        }
    }

    @Test
    func attachWithoutArgumentsNeedsThePickerAndAHome() async throws {
        try await Self.withHomeDirectory { home in
            // No picker: the non-interactive output, nothing asked.
            try await withChatHarness(userHomeDirectoryURL: home) { harness in
                #expect(await harness.controller.runAttachCommand(line: "/attach")
                    == ChatCommandOutcome(notices: [.requiresInteractiveHost(.attachmentSelection)]))
                #expect(await harness.host.interactions.isEmpty)
            }
            // A picker but no home to start from: the same.
            try await withChatHarness(hostCapabilities: [.attachmentPicker]) { harness in
                #expect(await harness.controller.runAttachCommand(line: "/attach")
                    == ChatCommandOutcome(notices: [.requiresInteractiveHost(.attachmentSelection)]))
                #expect(await harness.host.interactions.isEmpty)
            }
        }
    }

    @Test
    func attachWithoutArgumentsStagesThePickedFile() async throws {
        try await Self.withHomeDirectory { home in
            try await withChatHarness(
                hostCapabilities: [.attachmentPicker],
                userHomeDirectoryURL: home
            ) { harness in
                let controller = harness.controller
                let photo = try Self.writeFile("Pictures/photo.png", in: home)

                // The operator cancels.
                #expect(await controller.runAttachCommand(line: "/attach")
                    == ChatCommandOutcome(notices: [.attachmentSelectionCancelled]))
                #expect(await harness.host.interactions == [.pickAttachment(startingAt: home)])
                #expect(controller.pendingAttachments.isEmpty)

                await harness.host.clearInteractions()
                await harness.host.answerPickAttachment(photo)
                let outcome = await controller.runAttachCommand(line: "/attach")
                let staged = controller.pendingAttachments
                #expect(staged.map(\.fileURL?.path) == [photo.path])
                #expect(outcome == ChatCommandOutcome(notices: [
                    .attachmentsAdded(addedCount: 1, pendingCount: 1),
                    .pendingAttachments(staged),
                ]))
                #expect(await harness.host.interactions == [.pickAttachment(startingAt: home)])
            }
        }
    }

    @Test
    func thePendingAttachmentsAreHandedToOnePrompt() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let attachment = Self.memoryAttachment("a.png")
            controller.pendingAttachments = [attachment]

            #expect(controller.consumePendingAttachments() == [attachment])
            #expect(controller.pendingAttachments.isEmpty)
            #expect(controller.consumePendingAttachments().isEmpty)
        }
    }

    @Test
    func attachmentArgumentsSplitLikeAShell() throws {
        #expect(
            try ChatSessionController.splitAttachmentCommandArguments(
                #"a.png "my clip.mov" 'b c.png' d\ e.png"#
            ) == ["a.png", "my clip.mov", "b c.png", "d e.png"]
        )
        #expect(try ChatSessionController.splitAttachmentCommandArguments(#"trailing\"#) == [#"trailing\"#])
        #expect(throws: ChatAttachmentCommandError.unterminatedQuote) {
            try ChatSessionController.splitAttachmentCommandArguments(#"'open.png"#)
        }
        // The terminal's helper forwards to the shared one.
        #expect(
            try TerminalChat.splitAttachmentCommandArguments(#"a.png "b c.png""#)
                == ["a.png", "b c.png"]
        )
        #expect(ChatAttachmentCommandError.invalidDetachArgument("9").localizedDescription
            == "Invalid attachment selection: 9.")
        #expect(ChatAttachmentCommandError.unterminatedQuote.localizedDescription
            == "Unterminated quoted attachment path.")
    }

    // MARK: - Workspace paths

    @Test
    func workspacePathsExpandTheTildeOnlyWithAHome() {
        let workspace = URL(fileURLWithPath: "/project", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        func resolve(_ path: String, home: URL?, fileURLs: Bool = false) -> String {
            ChatSessionController.resolvedWorkspaceFileURL(
                from: path,
                workingDirectory: workspace,
                userHomeDirectoryURL: home,
                recognizingFileURLs: fileURLs
            ).path
        }

        #expect(resolve("~", home: home) == "/Users/me")
        #expect(resolve("~/Pictures/a.png", home: home) == "/Users/me/Pictures/a.png")
        // Without a home the tilde is an ordinary relative path.
        #expect(resolve("~", home: nil) == "/project/~")
        #expect(resolve("~/Pictures/a.png", home: nil) == "/project/~/Pictures/a.png")
        #expect(resolve("docs/../a.png", home: home) == "/project/a.png")
        #expect(resolve("/tmp/a.png", home: home) == "/tmp/a.png")
        #expect(resolve("file:///tmp/a.png", home: home, fileURLs: true) == "/tmp/a.png")
    }

    @Test
    func theControllerResolvesWithTheChannelsHome() async throws {
        try await Self.withHomeDirectory { home in
            try await withChatHarness(userHomeDirectoryURL: home) { harness in
                #expect(harness.controller.resolvedWorkspaceFileURL(from: "~/a.png").path
                    == home.appendingPathComponent("a.png").path)
                #expect(harness.controller.resolvedWorkspaceFileURL(from: "a.png").path
                    == harness.workspace.appendingPathComponent("a.png").standardizedFileURL.path)
            }
        }
        try await withChatHarness { harness in
            #expect(harness.controller.resolvedWorkspaceFileURL(from: "~/a.png").path
                == harness.workspace.appendingPathComponent("~/a.png").standardizedFileURL.path)
        }
    }

    // MARK: - /open candidates

    @Test
    func openCandidatesComeFromTheStagedAttachmentsAndTheTranscriptNewestFirst() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let workspace = harness.workspace
            let notes = try Self.writeFile("notes.md", in: workspace)
            let old = try Self.writeFile("old.md", in: workspace)
            let diagram = try Self.writeFile("diagram.png", in: workspace)
            let staged = try Self.writeFile("staged.png", in: workspace)

            controller.pendingAttachments = [
                AgentRuntimeAttachment(kind: .image, fileURL: staged, originalFilename: "staged.png"),
                // Held only in memory: nothing to open.
                Self.memoryAttachment("memory.png"),
            ]
            controller.transcript = [
                AgentRuntimeMessage(
                    role: .user,
                    content: "Look at ./old.md and https://example.com/a"
                ),
                AgentRuntimeMessage(role: .tool, content: "./notes.md is ignored"),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "See ./notes.md, https://example.com/a and ./missing.md.",
                    attachments: [
                        AgentRuntimeAttachment(kind: .image, fileURL: diagram, originalFilename: "diagram.png"),
                    ]
                ),
                AgentRuntimeMessage(role: .system, content: "/etc is ignored"),
            ]

            let expected = [
                ChatOpenCandidate(target: staged.path, display: "staged.png", kind: .file),
                ChatOpenCandidate(target: diagram.path, display: "diagram.png", kind: .file),
                ChatOpenCandidate(target: notes.path, display: "./notes.md", kind: .file),
                ChatOpenCandidate(target: "https://example.com/a", display: "https://example.com/a", kind: .url),
                ChatOpenCandidate(target: old.path, display: "./old.md", kind: .file),
            ]
            #expect(controller.openCandidates() == expected)

            // Without a menu the list is the non-interactive output.
            #expect(await controller.runOpenCommand(line: "/open")
                == ChatCommandOutcome(notices: [.requiresInteractiveHost(.openSelection(candidates: expected))]))
            #expect(await harness.host.interactions.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func openWithoutCandidatesSaysSo() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice, .externalOpen]) { harness in
            harness.controller.transcript = [
                AgentRuntimeMessage(role: .assistant, content: "Nothing to open here."),
            ]
            #expect(await harness.controller.runOpenCommand(line: "/open")
                == ChatCommandOutcome(notices: [.noOpenCandidates]))
            #expect(await harness.host.interactions.isEmpty)
        }
    }

    // MARK: - /open routing

    @Test
    func openOffersTheCandidatesInAMenuAndOpensTheChoice() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice, .externalOpen]) { harness in
            let controller = harness.controller
            let notes = try Self.writeFile("notes.md", in: harness.workspace)
            controller.transcript = [
                AgentRuntimeMessage(role: .assistant, content: "See ./notes.md and https://example.com/a"),
            ]
            let items = [
                ChatChoiceItem(id: "0", title: "./notes.md", detail: "file"),
                ChatChoiceItem(id: "1", title: "https://example.com/a", detail: "url"),
            ]
            let menu = ScriptedChatInteractionHost.Interaction.chooseOne(
                title: "Open file or URL",
                items: items,
                selectedID: "0"
            )

            await harness.host.answerChooseOne("1")
            let url = ChatOpenTarget(target: "https://example.com/a", kind: .url)
            #expect(await controller.runOpenCommand(line: "/open")
                == ChatCommandOutcome(notices: [.opening(url)]))
            #expect(await harness.host.interactions == [menu, .openExternal(url)])

            await harness.host.clearInteractions()
            await harness.host.answerChooseOne("0")
            let file = ChatOpenTarget(target: notes.path, kind: .file)
            #expect(await controller.runOpenCommand(line: "/open")
                == ChatCommandOutcome(notices: [.opening(file)]))
            #expect(await harness.host.interactions == [menu, .openExternal(file)])

            // The operator cancels: nothing is opened.
            await harness.host.clearInteractions()
            #expect(await controller.runOpenCommand(line: "/open")
                == ChatCommandOutcome(notices: [.nothingOpened]))
            #expect(await harness.host.interactions == [menu])
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func openOpensItsArgumentDirectly() async throws {
        try await Self.withHomeDirectory { home in
            try await withChatHarness(
                hostCapabilities: [.externalOpen],
                userHomeDirectoryURL: home
            ) { harness in
                let controller = harness.controller
                let notes = try Self.writeFile("docs/notes.md", in: harness.workspace)
                let homeNote = try Self.writeFile("home-note.txt", in: home)

                let url = ChatOpenTarget(target: "https://example.com/docs", kind: .url)
                #expect(await controller.runOpenCommand(line: "/open https://example.com/docs")
                    == ChatCommandOutcome(notices: [.opening(url)]))
                let mail = ChatOpenTarget(target: "mailto:dev@example.com", kind: .url)
                #expect(await controller.runOpenCommand(line: "/open mailto:dev@example.com")
                    == ChatCommandOutcome(notices: [.opening(mail)]))
                let file = ChatOpenTarget(target: notes.path, kind: .file)
                #expect(await controller.runOpenCommand(line: "/open docs/../docs/notes.md")
                    == ChatCommandOutcome(notices: [.opening(file)]))
                let homeFile = ChatOpenTarget(target: homeNote.path, kind: .file)
                #expect(await controller.runOpenCommand(line: "/open ~/home-note.txt")
                    == ChatCommandOutcome(notices: [.opening(homeFile)]))
                #expect(await harness.host.interactions == [
                    .openExternal(url),
                    .openExternal(mail),
                    .openExternal(file),
                    .openExternal(homeFile),
                ])

                // A missing file is never handed to the host.
                await harness.host.clearInteractions()
                #expect(await controller.runOpenCommand(line: "/open missing.md")
                    == ChatCommandOutcome(notices: [.openTargetNotFound(argument: "missing.md")]))
                #expect(await harness.host.interactions.isEmpty)

                // The platform refuses.
                await harness.host.failNextOpenExternal("The system file launcher failed with exit code 1.")
                #expect(await controller.runOpenCommand(line: "/open docs/notes.md")
                    == ChatCommandOutcome(notices: [
                        .operationFailed(description: "The system file launcher failed with exit code 1.")
                    ]))
                #expect(await harness.host.interactions == [.openExternal(file)])
                #expect(await harness.presenter.events.isEmpty)
            }
        }
    }

    @Test
    func openNeedsTheExternalOpenCapability() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let controller = harness.controller
            try Self.writeFile("notes.md", in: harness.workspace)
            controller.transcript = [
                AgentRuntimeMessage(role: .assistant, content: "See ./notes.md"),
            ]
            let unsupported = ChatCommandOutcome(notices: [
                .operationFailed(description: "Opening files is not supported by this channel.")
            ])

            #expect(await controller.runOpenCommand(line: "/open notes.md") == unsupported)
            #expect(await controller.runOpenCommand(line: "/open https://example.com") == unsupported)
            #expect(await harness.host.interactions.isEmpty)

            await harness.host.answerChooseOne("0")
            #expect(await controller.runOpenCommand(line: "/open") == unsupported)
            #expect(await harness.host.interactions.count == 1)
            #expect(await harness.host.interactions.contains { interaction in
                if case .openExternal = interaction { return true }
                return false
            } == false)
            #expect(ChatSessionNoticeText.text(for: unsupported.notices[0])
                == "ZenCODE: Opening files is not supported by this channel.\n")
        }
    }

    /// The terminal opens files and offers its picker only with an
    /// interactive terminal, like its menus; piped or inside a host app it
    /// offers neither.
    @ChatSessionActor
    @Test
    func theTerminalOffersOpeningAndThePickerOnlyWithAnInteractiveTerminal() {
        let interactive = TerminalInteractionHost(stdinIsTerminal: true, appMode: false)
        #expect(interactive.capabilities.isSuperset(of: [.externalOpen, .attachmentPicker, .singleChoice]))
        for appMode in [false, true] {
            let piped = TerminalInteractionHost(stdinIsTerminal: false, appMode: appMode)
            #expect(piped.capabilities.isDisjoint(with: [.externalOpen, .attachmentPicker, .singleChoice]))
        }
    }
}
