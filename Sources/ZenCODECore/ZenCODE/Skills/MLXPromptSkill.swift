//
//  MLXPromptSkill.swift
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

public struct MLXPromptSkillPayload: Equatable, Sendable {
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

public struct MLXPromptSkill: Identifiable, Hashable, Sendable {
    public let id: String
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
        self.id = sourceHash.nilIfBlank ?? canonicalName.nilIfBlank ?? UUID().uuidString.lowercased()
    }

    public init(payload: MLXPromptSkillPayload) {
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

public enum MLXPromptSkillError: LocalizedError {
    case unreadableFile(URL)
    case invalidFrontMatter(String)
    case emptySkillBody(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(url):
            return "Unable to read skill file \(url.lastPathComponent)."
        case let .invalidFrontMatter(filename):
            return "The file \(filename) has invalid front matter."
        case let .emptySkillBody(filename):
            return "The file \(filename) does not contain a usable skill body."
        }
    }
}
