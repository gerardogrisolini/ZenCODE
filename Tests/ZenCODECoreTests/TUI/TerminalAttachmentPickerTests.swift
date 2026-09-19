//
//  TerminalAttachmentPickerTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalAttachmentPickerTests {
    @Test
    func pickerEntriesIncludeDirectoriesAndSupportedImagesAndVideosOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-attachment-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".hidden-directory"),
            withIntermediateDirectories: false
        )
        try Data([0x00]).write(to: root.appendingPathComponent("photo.PNG"))
        try Data([0x00]).write(to: root.appendingPathComponent(".hidden.PNG"))
        try Data([0x00]).write(to: root.appendingPathComponent("clip.MP4"))
        try Data([0x00]).write(to: root.appendingPathComponent("notes.txt"))

        let entries = TerminalChat.attachmentPickerEntries(in: root)

        #expect(entries.map(\.title) == ["nested", "clip.MP4", "photo.PNG"])
        #expect(entries.first?.kind == .directory)
        #expect(entries.dropFirst().map(\.kind) == [.video, .image])
        #expect(!entries.contains { $0.title == "notes.txt" })
        #expect(!entries.contains { $0.title == ".hidden-directory" })
        #expect(!entries.contains { $0.title == ".hidden.PNG" })
    }

    @Test
    func attachmentUsageDocumentsPickerAndPathForms() {
        let usage = TerminalChat.renderAttachmentUsage()

        #expect(usage.contains("/attach                    Open the terminal attachment picker"))
        #expect(usage.contains("/attach <image-or-video-file> [file ...]"))
        #expect(usage.contains("/attach list"))
        #expect(usage.contains("/attach delete [all|attachment-number]"))
    }

    @Test
    func attachCommandIsAvailableWithoutAnArgument() {
        let descriptor = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).first { $0.command == "/attach" }

        #expect(descriptor?.requiresArgument == false)
        #expect(descriptor?.help.contains("terminal picker") == true)
    }

    #if os(macOS)
    @Test
    func pickerDetectsUnreadableDirectoriesInsteadOfTreatingThemAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-attachment-picker-permissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.path
            )
        }

        #expect(!TerminalChat.attachmentPickerCanReadDirectory(at: root))
        #expect(TerminalChat.attachmentPickerEntries(in: root).isEmpty)
    }
    #endif

    @Test
    func pickerResolvesSymlinkedDirectoriesBeforeClassifyingEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-attachment-picker-links-\(UUID().uuidString)")
        let target = root.appendingPathComponent("real-directory")
        let link = root.appendingPathComponent("linked-directory")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data([0x00]).write(to: target.appendingPathComponent("photo.png"))
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        let entries = TerminalChat.attachmentPickerEntries(in: root)
        let linkedEntry = try #require(
            entries.first { $0.title == "linked-directory" }
        )

        #expect(linkedEntry.kind == .directory)
        #expect(linkedEntry.path == target.standardizedFileURL.path)
        #expect(
            TerminalChat.attachmentPickerEntries(
                in: URL(fileURLWithPath: linkedEntry.path)
            ).map(\.title) == ["photo.png"]
        )
    }
}
