//
//  ACPAttachmentLimitsTests.swift
//  ZenCODE
//
//  What a `session/prompt` may attach to a turn: a file of the session's
//  workspace or of a temporary directory, no larger than the limit, and of a
//  media kind — a `resource` carrying a document is not an image.
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

@Suite
struct ACPAttachmentLimitsTests {
    private static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func resourceBlock(uri: String, mimeType: String = "image/png") -> [Any] {
        [[
            "type": "resource",
            "resource": [
                "uri": uri,
                "mimeType": mimeType,
            ],
        ] as [String: Any]]
    }

    @Test
    func aFileInsideTheWorkspaceIsRead() async throws {
        let workspace = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)

        let attachments = await ZenCODEACPBridge.promptAttachments(
            from: Self.resourceBlock(uri: file.absoluteString),
            renderedPromptText: "",
            cwd: workspace.path
        )

        #expect(attachments.count == 1)
        #expect(attachments.first?.kind == .image)
        #expect(attachments.first?.data == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test
    func aFileOfATemporaryDirectoryIsRead() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-shot-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let attachments = await ZenCODEACPBridge.promptAttachments(
            from: Self.resourceBlock(uri: file.path),
            renderedPromptText: "",
            cwd: workspace.path
        )

        #expect(attachments.count == 1)
    }

    /// A prompt is the client's: it must not turn the agent into a reader of
    /// arbitrary paths, whose content would be forwarded to the provider.
    @Test
    func aFileOutsideTheWorkspaceAndTheTemporaryDirectoriesIsNotRead() async throws {
        let outside = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("acp-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let file = outside.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        let workspace = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let attachments = await ZenCODEACPBridge.promptAttachments(
            from: Self.resourceBlock(uri: file.path),
            renderedPromptText: "",
            cwd: workspace.path
        )

        #expect(attachments.isEmpty)
        #expect(
            !ZenCODEACPBridge.isReadableAttachmentLocation(file, cwd: workspace.path)
        )
    }

    @Test
    func aFileLargerThanTheLimitIsNotRead() async throws {
        let workspace = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("huge.png")
        let oversized = Data(repeating: 0, count: ZenCODEACPBridge.maximumAttachmentBytes + 1)
        try oversized.write(to: file)

        let attachments = await ZenCODEACPBridge.promptAttachments(
            from: Self.resourceBlock(uri: file.path),
            renderedPromptText: "",
            cwd: workspace.path
        )

        #expect(attachments.isEmpty)
    }
}
