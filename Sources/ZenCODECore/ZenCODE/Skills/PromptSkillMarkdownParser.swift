//
//  PromptSkillMarkdownParser.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(CryptoKit)

import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum PromptSkillMarkdownParser {
    public static func parse(url: URL) throws -> PromptSkillPayload {
        #if os(macOS)
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        #endif

        guard let markdownData = try? Data(contentsOf: url),
              let markdown = String(data: markdownData, encoding: .utf8) else {
            throw MLXPromptSkillError.unreadableFile(url)
        }

        return try parse(
            markdown: markdown,
            sourceFilename: url.lastPathComponent,
            sourceDirectoryPath: url.deletingLastPathComponent().path
        )
    }

    public static func parse(
        markdown: String,
        sourceFilename: String,
        sourceDirectoryPath: String? = nil
    ) throws -> PromptSkillPayload {
        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let split = try splitFrontMatter(from: normalizedMarkdown, sourceFilename: sourceFilename)
        let metadata = parseFrontMatter(split.frontMatter)
        let promptBody = split.body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !promptBody.isEmpty else {
            throw MLXPromptSkillError.emptySkillBody(sourceFilename)
        }

        let explicitTitle =
            metadata["title"]
            ?? metadata["display_title"]
            ?? metadata["displayTitle"]
            ?? metadata["label"]
        let metadataName = metadata["name"]
        let preferredHeading = firstPreferredHeading(in: promptBody)
        let fallbackTitleSource = explicitTitle
            ?? metadataName.flatMap(displayTitle(fromMetadataName:))
            ?? preferredHeading
            ?? sourceFilename.replacingOccurrences(of: ".md", with: "")
        let canonicalName = normalizedCanonicalName(
            metadataName
                ?? explicitTitle
                ?? preferredHeading
                ?? sourceFilename.replacingOccurrences(of: ".md", with: "")
        )
        let title = normalizedTitle(
            fallbackTitleSource.isEmpty
                ? prettyTitle(from: canonicalName)
                : fallbackTitleSource
        )
        let summary = normalizedSummary(
            metadata["description"]
                ?? firstParagraph(in: promptBody)
                ?? "Imported skill from \(sourceFilename)."
        )
        let symbolName = metadata["symbol"] ?? metadata["symbolName"] ?? metadata["sf_symbol"]

        return PromptSkillPayload(
            canonicalName: canonicalName,
            title: title,
            summary: summary,
            symbolName: normalizedOptional(symbolName),
            rawMarkdown: normalizedMarkdown,
            promptBody: promptBody,
            sourceFilename: sourceFilename,
            sourceDirectoryPath: normalizedOptional(sourceDirectoryPath),
            sourceHash: hash(normalizedMarkdown)
        )
    }

    private static func splitFrontMatter(
        from markdown: String,
        sourceFilename: String
    ) throws -> (frontMatter: String, body: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return ("", markdown)
        }

        guard let closingIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            throw MLXPromptSkillError.invalidFrontMatter(sourceFilename)
        }

        let frontMatterLines = Array(lines[1..<closingIndex])
        let bodyStartIndex = lines.index(after: closingIndex)
        let bodyLines = bodyStartIndex < lines.endIndex ? Array(lines[bodyStartIndex...]) : []

        return (
            frontMatterLines.joined(separator: "\n"),
            bodyLines.joined(separator: "\n")
        )
    }

    private static func parseFrontMatter(_ rawFrontMatter: String) -> [String: String] {
        guard !rawFrontMatter.isEmpty else {
            return [:]
        }

        var metadata: [String: String] = [:]
        for rawLine in rawFrontMatter.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            guard let separatorIndex = line.firstIndex(of: ":") else {
                continue
            }

            let key = line[..<separatorIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let unquotedValue = unquote(value)

            guard !key.isEmpty, !unquotedValue.isEmpty else {
                continue
            }

            metadata[key] = unquotedValue
        }

        return metadata
    }

    private static func firstPreferredHeading(in body: String) -> String? {
        let headings = headings(in: body)
        if let preferredHeading = headings.first(where: {
            !genericSkillHeadingTitles.contains(
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            )
        }) {
            return preferredHeading
        }

        return headings.first
    }

    private static func headings(in body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        var headings: [String] = []
        var index = 0

        while index < lines.count {
            let trimmedLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("#") {
                let heading = trimmedLine.drop { $0 == "#" || $0 == " " }
                let normalizedHeading = String(heading).trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedHeading.isEmpty {
                    headings.append(normalizedHeading)
                }
                index += 1
                continue
            }

            if !trimmedLine.isEmpty,
               index + 1 < lines.count,
               isSetextHeadingUnderline(lines[index + 1]) {
                headings.append(trimmedLine)
                index += 2
                continue
            }

            index += 1
        }

        return headings
    }

    private static func firstParagraph(in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        var paragraphLines: [String] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty {
                if !paragraphLines.isEmpty {
                    break
                }
                continue
            }

            guard !trimmedLine.hasPrefix("#"), !trimmedLine.hasPrefix("```") else {
                continue
            }

            paragraphLines.append(trimmedLine)
        }

        let paragraph = paragraphLines.joined(separator: " ")
        return paragraph.isEmpty ? nil : paragraph
    }

    private static func normalizedCanonicalName(_ value: String) -> String {
        let loweredValue = value.lowercased()
        let scalars = loweredValue.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }

        let candidate = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return candidate.isEmpty ? UUID().uuidString.lowercased() : candidate
    }

    private static func normalizedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedSummary(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func displayTitle(fromMetadataName rawValue: String) -> String? {
        let normalizedValue = normalizedOptional(rawValue)
        guard let normalizedValue else {
            return nil
        }

        let looksLikeIdentifier =
            normalizedValue.contains("-")
            || normalizedValue.contains("_")
            || !normalizedValue.contains(" ")
                && normalizedValue == normalizedValue.lowercased()

        if looksLikeIdentifier {
            return prettyTitle(from: normalizedCanonicalName(normalizedValue))
        }

        return normalizedValue
    }

    private static func prettyTitle(from canonicalName: String) -> String {
        canonicalName
            .split(separator: "-")
            .map { component in
                let normalizedComponent = component.lowercased()
                if let preferredComponent = preferredTitleComponents[normalizedComponent] {
                    return preferredComponent
                }
                return component.prefix(1).uppercased() + String(component.dropFirst())
            }
            .joined(separator: " ")
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }

        return value
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isSetextHeadingUnderline(_ rawLine: String) -> Bool {
        let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return false
        }

        return trimmedLine.allSatisfy { $0 == "=" } || trimmedLine.allSatisfy { $0 == "-" }
    }
}
