//
//  PromptSkill.swift
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
import ToolCore

public struct PromptSkillPayload: Equatable, Sendable {
    public let canonicalName: String
    public let title: String
    public let summary: String
    public let symbolName: String?
    public let rawMarkdown: String
    public let promptBody: String
    public let sourceFilename: String
    public let sourceDirectoryPath: String?
    public let sourceHash: String
    public let githubRepository: String?
    public let githubReference: String?
    public let githubRevision: String?
    public let githubSkillPath: String?

    public init(
        canonicalName: String,
        title: String,
        summary: String,
        symbolName: String? = nil,
        rawMarkdown: String,
        promptBody: String,
        sourceFilename: String,
        sourceDirectoryPath: String? = nil,
        sourceHash: String,
        githubRepository: String? = nil,
        githubReference: String? = nil,
        githubRevision: String? = nil,
        githubSkillPath: String? = nil
    ) {
        self.canonicalName = canonicalName
        self.title = title
        self.summary = summary
        self.symbolName = symbolName
        self.rawMarkdown = rawMarkdown
        self.promptBody = promptBody
        self.sourceFilename = sourceFilename
        self.sourceDirectoryPath = sourceDirectoryPath
        self.sourceHash = sourceHash
        self.githubRepository = githubRepository
        self.githubReference = githubReference
        self.githubRevision = githubRevision
        self.githubSkillPath = githubSkillPath
    }
}

/// An installed prompt skill. Its identity is ``canonicalName``: the `name:`
/// of its `SKILL.md` front matter is the only identifier used by profiles,
/// session selections, and the skill tools. ``sourceHash`` is a fingerprint of
/// the content, kept as metadata; it changes with every edit of the skill and
/// is never an identifier or a comparison key.
public struct PromptSkill: Hashable, Sendable {
    public let canonicalName: String
    public let title: String
    public let summary: String
    public let symbolName: String?
    public let promptBody: String
    public let sourceFilename: String
    public let sourceDirectoryPath: String?
    public let sourceHash: String

    public init(
        canonicalName: String,
        title: String,
        summary: String,
        symbolName: String? = nil,
        promptBody: String,
        sourceFilename: String = "SKILL.md",
        sourceDirectoryPath: String? = nil,
        sourceHash: String
    ) {
        self.canonicalName = canonicalName
        self.title = title
        self.summary = summary
        self.symbolName = symbolName
        self.promptBody = promptBody
        self.sourceFilename = sourceFilename
        self.sourceDirectoryPath = sourceDirectoryPath
        self.sourceHash = sourceHash
    }

    public init(payload: PromptSkillPayload) {
        self.init(
            canonicalName: payload.canonicalName,
            title: payload.title,
            summary: payload.summary,
            symbolName: payload.symbolName,
            promptBody: payload.promptBody,
            sourceFilename: payload.sourceFilename,
            sourceDirectoryPath: payload.sourceDirectoryPath,
            sourceHash: payload.sourceHash
        )
    }
}

public enum PromptSkillError: LocalizedError {
    case unreadableFile(URL)
    case unsafeFile(URL)
    case fileTooLarge(URL, maximumBytes: Int)
    case invalidFrontMatter(String)
    case emptySkillBody(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(url):
            return "Unable to read skill file \(url.lastPathComponent)."
        case let .unsafeFile(url):
            return "Refusing to read unsafe skill file \(url.lastPathComponent)."
        case let .fileTooLarge(url, maximumBytes):
            return "Skill file \(url.lastPathComponent) exceeds the \(maximumBytes)-byte limit."
        case let .invalidFrontMatter(filename):
            return "The file \(filename) has invalid front matter."
        case let .emptySkillBody(filename):
            return "The file \(filename) does not contain a usable skill body."
        }
    }
}
