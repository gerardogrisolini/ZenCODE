//
//  TerminalChatOpenCommandTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatOpenCommandTests {
    @Test
    func extractsHTTPURLsFromMessageText() {
        let candidates = TerminalChat.extractOpenCandidates(
            from: "See https://example.com/docs and (http://foo.test/page).",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        #expect(candidates.map(\.target) == [
            "https://example.com/docs",
            "http://foo.test/page"
        ])
        #expect(candidates.allSatisfy { $0.kind == .url })
    }

        @Test
    func extractsCommonURLSchemes() {
        let candidates = TerminalChat.extractOpenCandidates(
            from: "mail me at mailto:dev@example.com or ftp://files.test/pub or call tel:+15551234",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        #expect(candidates.map(\.target) == [
            "mailto:dev@example.com",
            "ftp://files.test/pub",
            "tel:+15551234"
        ])
        #expect(candidates.allSatisfy { $0.kind == .url })
    }

    @Test
    func ignoresUnknownOrTimeLikeSchemes() {
        let candidates = TerminalChat.extractOpenCandidates(
            from: "meeting at 12:30 and gopher://old.test/x",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        #expect(candidates.isEmpty)
    }

    @Test
    func ignoresPlainWordsThatAreNotPathsOrURLs() {
        let candidates = TerminalChat.extractOpenCandidates(
            from: "just some normal words here",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        #expect(candidates.isEmpty)
    }

    @Test
    func extractsExistingFilePathsRelativeToWorkingDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("notes.md")
        try "hi".write(to: fileURL, atomically: true, encoding: .utf8)

        let candidates = TerminalChat.extractOpenCandidates(
            from: "Check ./notes.md and ./missing.md",
            workingDirectory: directory
        )

                #expect(candidates.count == 1)
        #expect(candidates.first?.kind == .file)
        #expect(candidates.first?.target == fileURL.standardizedFileURL.path)
    }

    @Test
    func attachmentBackedByFileBecomesCandidate() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("diagram.png")
        try Data([0x1]).write(to: fileURL)

        let attachment = AgentRuntimeAttachment(
            kind: .image,
            fileURL: fileURL,
            originalFilename: "diagram.png"
        )

        let candidate = TerminalChat.attachmentCandidate(from: attachment)
        #expect(candidate?.kind == .file)
        #expect(candidate?.display == "diagram.png")
        #expect(candidate?.target == fileURL.standardizedFileURL.path)
    }

    @Test
    func attachmentWithoutFileURLIsIgnored() {
        let attachment = AgentRuntimeAttachment(
            kind: .image,
            data: Data([0x1]),
            originalFilename: "inline.png"
        )

        #expect(TerminalChat.attachmentCandidate(from: attachment) == nil)
    }
}
