//
//  TerminalChat+Open.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini.
//

import Foundation

/// A file path or URL referenced somewhere in the conversation that the
/// `/open` command can hand off to the system `open` utility.
struct TerminalOpenCandidate: Equatable {
    enum Kind: Equatable {
        case file
        case url
    }

    /// The value passed to `open` (an absolute file path or a URL string).
    let target: String
    /// The label shown in the selection menu (kept human readable).
    let display: String
    let kind: Kind
}

extension TerminalChat {
    public func handleOpenCommand(_ command: String) async {
        let argument = String(command.dropFirst("/open".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Direct form: `/open <file-or-url>` opens the argument without a menu.
        if !argument.isEmpty {
            await openDirectArgument(argument)
            return
        }

        let candidates = collectOpenCandidates()
        guard !candidates.isEmpty else {
            await writeSystemMessage("No files or URLs found in this conversation.\n")
            return
        }

        guard stdinIsTerminal else {
            await writeSystemMessage(Self.renderOpenCandidateList(candidates))
            await writeSystemMessage("Selecting an item to open requires an interactive terminal.\n")
            return
        }

        let items = candidates.enumerated().map { index, candidate in
            TerminalCheckboxMenuItem(
                value: index,
                title: candidate.display,
                detail: candidate.kind == .url ? "url" : "file"
            )
        }

        guard let selectedIndex = TerminalCheckboxMenu.selectOne(
            title: "Open file or URL",
            items: items,
            selected: 0,
            reservedBottomRows: await statusBar.reservedRowsForOverlay()
        ) else {
            await writeSystemMessage("Nothing opened.\n")
            return
        }

        await openTarget(candidates[selectedIndex].target)
    }

        private func openDirectArgument(_ argument: String) async {
        if Self.urlCandidate(from: argument) != nil {
            await openTarget(argument)
            return
        }

        let resolved = resolvedOpenURL(from: argument)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            await writeFailureMessage("ZenCODE: file not found: \(argument)\n")
            return
        }
        await openTarget(resolved.path)
    }

    private func openTarget(_ target: String) async {
        do {
            try await Self.runOpen(target: target)
            await writeSystemMessage("Opening \(target)\n")
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    /// Scans the current conversation transcript (newest turns first) and
    /// returns the referenced files and URLs ordered from most to least recent,
    /// removing duplicates while keeping the most recent occurrence.
        func collectOpenCandidates() -> [TerminalOpenCandidate] {
        var seen = Set<String>()
        var ordered: [TerminalOpenCandidate] = []

        func append(_ candidate: TerminalOpenCandidate) {
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

        for message in activeSessionTranscript.reversed() {
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
                workingDirectory: configuration.workingDirectory
            ) {
                append(candidate)
            }
        }

        return ordered
    }

    /// Builds an open candidate for an attachment that is backed by a file on
    /// disk. Attachments held only as in-memory data are skipped because `open`
    /// needs a real path.
    static func attachmentCandidate(
        from attachment: AgentRuntimeAttachment
    ) -> TerminalOpenCandidate? {
        guard let fileURL = attachment.fileURL else {
            return nil
        }
        let resolved = fileURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return TerminalOpenCandidate(
            target: resolved.path,
            display: attachment.originalFilename,
            kind: .file
        )
    }

    /// Extracts file paths and http(s) URLs from a single message body, keeping
    /// the order in which they appear in the text.
    static func extractOpenCandidates(
        from text: String,
        workingDirectory: URL
    ) -> [TerminalOpenCandidate] {
        var candidates: [TerminalOpenCandidate] = []
        var seen = Set<String>()

        for rawToken in tokenize(text) {
            let token = trimToken(rawToken)
            guard !token.isEmpty else {
                continue
            }

            if let url = urlCandidate(from: token) {
                if seen.insert(url.target).inserted {
                    candidates.append(url)
                }
                continue
            }

            if let file = fileCandidate(from: token, workingDirectory: workingDirectory) {
                if seen.insert(file.target).inserted {
                    candidates.append(file)
                }
            }
        }

        return candidates
    }

    private static func tokenize(_ text: String) -> [Substring] {
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
    private static func trimToken(_ token: Substring) -> String {
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
    private static let authoritySchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "sftp", "ssh", "file", "smb", "vnc"
    ]

    /// Schemes that address a resource without an authority component, such as
    /// `mailto:user@example.com` or `tel:+123456789`.
    private static let schemelessOpaqueSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio"
    ]

    private static func urlCandidate(from token: String) -> TerminalOpenCandidate? {
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
            return TerminalOpenCandidate(target: token, display: token, kind: .url)
        }

        if schemelessOpaqueSchemes.contains(scheme) {
            let body = token[schemeRange.upperBound...]
            guard !body.isEmpty, URL(string: token) != nil else {
                return nil
            }
            return TerminalOpenCandidate(target: token, display: token, kind: .url)
        }

        return nil
    }

    private static func fileCandidate(
        from token: String,
        workingDirectory: URL
    ) -> TerminalOpenCandidate? {
        // Only treat tokens that look like paths to avoid matching plain words.
        let looksLikePath = token.hasPrefix("/")
            || token.hasPrefix("~/")
            || token.hasPrefix("./")
            || token.contains("/")
        guard looksLikePath else {
            return nil
        }

        let resolved = resolveOpenURL(from: token, workingDirectory: workingDirectory)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return TerminalOpenCandidate(
            target: resolved.path,
            display: token,
            kind: .file
        )
    }

    private func resolvedOpenURL(from rawPath: String) -> URL {
        Self.resolveOpenURL(from: rawPath, workingDirectory: configuration.workingDirectory)
    }

    private static func resolveOpenURL(
        from rawPath: String,
        workingDirectory: URL
    ) -> URL {
        let expandedPath: String
        if rawPath == "~" {
            expandedPath = UserHomeDirectory.current().path
        } else if rawPath.hasPrefix("~/") {
            expandedPath = UserHomeDirectory.current()
                .appendingPathComponent(String(rawPath.dropFirst(2)))
                .path
        } else {
            expandedPath = rawPath
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        return workingDirectory
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }

    static func renderOpenCandidateList(_ candidates: [TerminalOpenCandidate]) -> String {
        let lines = candidates.enumerated().map { index, candidate -> String in
            let kind = candidate.kind == .url ? "url" : "file"
            return "  \(index + 1). \(candidate.display) (\(kind))"
        }
        return """
        Files and URLs in this conversation:
        \(lines.joined(separator: "\n"))

        """
    }

    private static func runOpen(target: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let openURL = URL(fileURLWithPath: "/usr/bin/open")
            guard FileManager.default.isExecutableFile(atPath: openURL.path) else {
                throw TerminalOpenCommandError.openUnavailable
            }
            let process = Process()
            process.executableURL = openURL
            process.arguments = [target]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw TerminalOpenCommandError.openFailed(process.terminationStatus)
            }
        }.value
    }
}

private enum TerminalOpenCommandError: LocalizedError {
    case openUnavailable
    case openFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .openUnavailable:
            return "Opening files requires /usr/bin/open on macOS."
        case let .openFailed(exitCode):
            return "open failed with exit code \(exitCode)."
        }
    }
}
