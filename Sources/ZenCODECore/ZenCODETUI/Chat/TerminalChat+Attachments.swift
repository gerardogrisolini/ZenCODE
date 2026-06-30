//
//  TerminalChat+Attachments.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

extension TerminalChat {
    public func handleAttachCommand(_ command: String) throws {
        let rawArguments = String(command.dropFirst("/attach".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawArguments.isEmpty else {
            writeSystemMessage(Self.renderAttachmentUsage())
            return
        }

        let paths = try Self.splitAttachmentCommandArguments(rawArguments)
        guard !paths.isEmpty else {
            writeSystemMessage(Self.renderAttachmentUsage())
            return
        }

        let urls = paths.map { resolvedAttachmentURL(from: $0) }
        let attachments = try AgentRuntimeAttachmentStore.importRuntimeAttachments(from: urls)
        pendingAttachments.append(contentsOf: attachments)

        let noun = attachments.count == 1 ? "attachment" : "attachments"
        writeSystemMessage(
            "Added \(attachments.count) \(noun). \(pendingAttachments.count) pending.\n"
        )
        writePendingAttachments()
    }

    public func handleDetachCommand(_ command: String) throws {
        let rawArgument = String(command.dropFirst("/detach".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !pendingAttachments.isEmpty else {
            writeSystemMessage("No pending attachments.\n")
            return
        }

        guard !rawArgument.isEmpty else {
            writeSystemMessage(Self.renderDetachUsage())
            return
        }

        if rawArgument.lowercased() == "all" {
            pendingAttachments.removeAll()
            writeSystemMessage("Removed all pending attachments.\n")
            return
        }

        guard let index = Int(rawArgument), index > 0, index <= pendingAttachments.count else {
            throw TerminalAttachmentCommandError.invalidDetachArgument(rawArgument)
        }

        let removedAttachment = pendingAttachments.remove(at: index - 1)
        writeSystemMessage(
            "Removed attachment: \(removedAttachment.originalFilename)\n"
        )
        writePendingAttachments()
    }

    public func writePendingAttachments() {
        guard !pendingAttachments.isEmpty else {
            writeSystemMessage("No pending attachments.\n")
            return
        }

        let lines = pendingAttachments.enumerated().map { index, attachment in
            Self.renderAttachmentLine(number: index + 1, attachment: attachment)
        }
        writeSystemMessage(
            """
            Pending attachments:
            \(lines.joined(separator: "\n"))
            Send a prompt to include them, or press return on an empty prompt.

            """
        )
    }

    public func consumePendingAttachmentsForPrompt() -> [AgentRuntimeAttachment] {
        let attachments = pendingAttachments
        pendingAttachments.removeAll()
        return attachments
    }

    public static func renderAttachmentUsage() -> String {
        "Usage: /attach <image-or-video-file> [file ...]\n"
    }

    public static func renderDetachUsage() -> String {
        "Usage: /detach [all|attachment-number]\n"
    }

    public static func renderAttachmentLine(
        number: Int,
        attachment: AgentRuntimeAttachment
    ) -> String {
        var details = [
            attachment.kind.rawValue,
            attachment.contentType?.nilIfBlank
        ].compactMap { $0 }

        if let byteCount = AgentRuntimeAttachmentStore.byteCount(for: attachment) {
            details.append(Self.renderByteCount(byteCount))
        }

        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "  \(number). \(attachment.originalFilename)\(suffix)"
    }

    public static func splitAttachmentCommandArguments(_ rawArguments: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaping = false

        for character in rawArguments {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

                        if character == "\\" {
                isEscaping = true
                continue
            }

            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                activeQuote = character
                continue
            }

            if character.isShellWhitespace {
                if !current.isEmpty {
                    arguments.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if isEscaping {
            current.append("\\")
        }
        if activeQuote != nil {
            throw TerminalAttachmentCommandError.unterminatedQuote
        }
        if !current.isEmpty {
            arguments.append(current)
        }
        return arguments
    }

    private func resolvedAttachmentURL(from rawPath: String) -> URL {
        let expandedPath: String
        if rawPath == "~" {
            expandedPath = MLXUserHomeDirectory.current().path
        } else if rawPath.hasPrefix("~/") {
            expandedPath = MLXUserHomeDirectory.current()
                .appendingPathComponent(String(rawPath.dropFirst(2)))
                .path
        } else {
            expandedPath = rawPath
        }

        if let fileURL = URL(string: expandedPath),
           fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        return configuration.workingDirectory
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }

    private static func renderByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(byteCount),
            countStyle: .file
        )
    }
}

private enum TerminalAttachmentCommandError: LocalizedError {
    case invalidDetachArgument(String)
    case unterminatedQuote

    var errorDescription: String? {
        switch self {
        case let .invalidDetachArgument(argument):
            return "Invalid attachment selection: \(argument)."
        case .unterminatedQuote:
            return "Unterminated quoted attachment path."
        }
    }
}

private extension Character {
    var isShellWhitespace: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
