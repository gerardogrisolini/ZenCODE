//
//  ChatSessionController+WorkspaceReferences.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// How the workspace commands read what the operator names: paths relative to
/// the working directory or to the user's home, the files and URLs the
/// conversation mentions (`/open`), and the shell-like arguments of `/attach`.
///
/// The pure helpers are `nonisolated` and take everything they read as
/// arguments; the instance helpers add the controller's working directory and
/// the home folder of its ``ChatSessionEnvironment``.
extension ChatSessionController {
    // MARK: - Paths

    /// The file URL `rawPath` names.
    ///
    /// A leading `~` or `~/` stands for `userHomeDirectoryURL`, and stays as
    /// it is when the channel gave no home. An absolute path is taken as it
    /// is, anything else is relative to `workingDirectory`. With
    /// `recognizingFileURLs`, a `file://` URL names its own file.
    nonisolated static func resolvedWorkspaceFileURL(
        from rawPath: String,
        workingDirectory: URL,
        userHomeDirectoryURL: URL?,
        recognizingFileURLs: Bool = false
    ) -> URL {
        let expandedPath: String
        if let userHomeDirectoryURL, rawPath == "~" {
            expandedPath = userHomeDirectoryURL.path
        } else if let userHomeDirectoryURL, rawPath.hasPrefix("~/") {
            expandedPath = userHomeDirectoryURL
                .appendingPathComponent(String(rawPath.dropFirst(2)))
                .path
        } else {
            expandedPath = rawPath
        }

        if recognizingFileURLs,
           let fileURL = URL(string: expandedPath),
           fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        return workingDirectory
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }

    /// ``resolvedWorkspaceFileURL(from:workingDirectory:userHomeDirectoryURL:recognizingFileURLs:)``
    /// in the controller's working directory, with the channel's home.
    func resolvedWorkspaceFileURL(
        from rawPath: String,
        recognizingFileURLs: Bool = false
    ) -> URL {
        Self.resolvedWorkspaceFileURL(
            from: rawPath,
            workingDirectory: workingDirectory,
            userHomeDirectoryURL: environment.userHomeDirectoryURL,
            recognizingFileURLs: recognizingFileURLs
        )
    }

    // MARK: - /open candidates

    /// The files and URLs `/open` offers, most recent first: the staged
    /// attachments, then the user and assistant messages of the transcript
    /// from the newest, each with its attachments before the references in
    /// its text. A target listed once keeps its most recent occurrence.
    func openCandidates() -> [ChatOpenCandidate] {
        var seen = Set<String>()
        var ordered: [ChatOpenCandidate] = []

        func append(_ candidate: ChatOpenCandidate) {
            guard seen.insert(candidate.target).inserted else {
                return
            }
            ordered.append(candidate)
        }

        // Pending attachments are the most recent references the user staged.
        for attachment in pendingAttachments.reversed() {
            if let candidate = Self.attachmentCandidate(from: attachment) {
                append(candidate)
            }
        }

        for message in transcript.reversed() {
            guard message.role == .user || message.role == .assistant else {
                continue
            }
            for attachment in message.attachments {
                if let candidate = Self.attachmentCandidate(from: attachment) {
                    append(candidate)
                }
            }
            for candidate in Self.extractOpenCandidates(
                from: message.content,
                workingDirectory: workingDirectory,
                userHomeDirectoryURL: environment.userHomeDirectoryURL
            ) {
                append(candidate)
            }
        }

        return ordered
    }

    /// The candidate of an attachment backed by a file on disk. Attachments
    /// held only as in-memory data are skipped, because opening needs a real
    /// path.
    nonisolated static func attachmentCandidate(
        from attachment: AgentRuntimeAttachment
    ) -> ChatOpenCandidate? {
        guard let fileURL = attachment.fileURL else {
            return nil
        }
        let resolved = fileURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return ChatOpenCandidate(
            target: resolved.path,
            display: attachment.originalFilename,
            kind: .file
        )
    }

    /// The existing file paths and the URLs of a single message body, in the
    /// order they appear in the text. Paths resolve as in
    /// ``resolvedWorkspaceFileURL(from:workingDirectory:userHomeDirectoryURL:recognizingFileURLs:)``.
    nonisolated static func extractOpenCandidates(
        from text: String,
        workingDirectory: URL,
        userHomeDirectoryURL: URL?
    ) -> [ChatOpenCandidate] {
        var candidates: [ChatOpenCandidate] = []
        var seen = Set<String>()

        for rawToken in openTokens(in: text) {
            let token = trimmedOpenToken(rawToken)
            guard !token.isEmpty else {
                continue
            }

            if let url = urlCandidate(from: token) {
                if seen.insert(url.target).inserted {
                    candidates.append(url)
                }
                continue
            }

            if let file = fileCandidate(
                from: token,
                workingDirectory: workingDirectory,
                userHomeDirectoryURL: userHomeDirectoryURL
            ) {
                if seen.insert(file.target).inserted {
                    candidates.append(file)
                }
            }
        }

        return candidates
    }

    private nonisolated static func openTokens(in text: String) -> [Substring] {
        text.split { character in
            character == " "
                || character == "\n"
                || character == "\t"
                || character == "\r"
                || character == "`"
                || character == "\""
                || character == "'"
                || character == "<"
                || character == ">"
                || character == "|"
        }
    }

    /// Strips Markdown and punctuation noise that commonly surrounds inline
    /// references, such as trailing commas, parentheses, or list markers.
    private nonisolated static func trimmedOpenToken(_ token: Substring) -> String {
        let leading = CharacterSet(charactersIn: "([{*_~#-")
        let trailing = CharacterSet(charactersIn: ".,;:!?)]}*_~")
        var result = String(token)
        while let first = result.unicodeScalars.first, leading.contains(first) {
            result.removeFirst()
        }
        while let last = result.unicodeScalars.last, trailing.contains(last) {
            result.removeLast()
        }
        return result
    }

    /// Schemes that use an authority component (`scheme://host/...`) and so
    /// require a host to be considered a valid open candidate.
    private nonisolated static let authoritySchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "sftp", "ssh", "file", "smb", "vnc"
    ]

    /// Schemes that address a resource without an authority component, such as
    /// `mailto:user@example.com` or `tel:+123456789`.
    private nonisolated static let schemelessOpaqueSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio"
    ]

    /// The URL candidate `token` names, or `nil` when it is not a URL of a
    /// known scheme. `/open <argument>` uses it to tell a URL from a path.
    nonisolated static func urlCandidate(from token: String) -> ChatOpenCandidate? {
        guard let schemeRange = token.range(of: ":") else {
            return nil
        }
        let scheme = token[token.startIndex..<schemeRange.lowerBound].lowercased()
        guard !scheme.isEmpty else {
            return nil
        }

        if authoritySchemes.contains(scheme) {
            let prefix = "\(scheme)://"
            guard token.lowercased().hasPrefix(prefix) else {
                return nil
            }
            guard let url = URL(string: token), url.host != nil else {
                return nil
            }
            return ChatOpenCandidate(target: token, display: token, kind: .url)
        }

        if schemelessOpaqueSchemes.contains(scheme) {
            let body = token[schemeRange.upperBound...]
            guard !body.isEmpty, URL(string: token) != nil else {
                return nil
            }
            return ChatOpenCandidate(target: token, display: token, kind: .url)
        }

        return nil
    }

    private nonisolated static func fileCandidate(
        from token: String,
        workingDirectory: URL,
        userHomeDirectoryURL: URL?
    ) -> ChatOpenCandidate? {
        // Only treat tokens that look like paths to avoid matching plain words.
        let looksLikePath = token.hasPrefix("/")
            || token.hasPrefix("~/")
            || token.hasPrefix("./")
            || token.contains("/")
        guard looksLikePath else {
            return nil
        }

        let resolved = resolvedWorkspaceFileURL(
            from: token,
            workingDirectory: workingDirectory,
            userHomeDirectoryURL: userHomeDirectoryURL
        )
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return ChatOpenCandidate(
            target: resolved.path,
            display: token,
            kind: .file
        )
    }

    // MARK: - /attach arguments

    /// Splits the `/attach` arguments like a shell: whitespace separates
    /// them, single or double quotes keep spaces, and a backslash keeps the
    /// next character (a trailing one stays). Throws
    /// ``ChatAttachmentCommandError/unterminatedQuote`` for an open quote.
    nonisolated static func splitAttachmentCommandArguments(
        _ rawArguments: String
    ) throws -> [String] {
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

            if character.isAttachmentArgumentSeparator {
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
            throw ChatAttachmentCommandError.unterminatedQuote
        }
        if !current.isEmpty {
            arguments.append(current)
        }
        return arguments
    }
}

private extension Character {
    /// Whitespace or a newline, which separates `/attach` arguments.
    var isAttachmentArgumentSeparator: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
