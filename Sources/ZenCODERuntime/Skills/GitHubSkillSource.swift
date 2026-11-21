//
//  GitHubSkillSource.swift
//  ZenCODE
//
//  Parsing of a GitHub skill URL into its owner, repository, clone URL and
//  optional tree or blob selector.
//

import Foundation
import ToolCore

struct GitHubSkillSource: Equatable {
    enum SelectorKind: Equatable {
        case tree
        case blob
    }

    struct Selector: Equatable {
        var kind: SelectorKind
        var components: [String]
    }

    var originalURL: URL
    var owner: String
    var repository: String
    var cloneURL: URL
    var selector: Selector?

    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            throw PromptSkillInstallerError.invalidGitHubURL(url.absoluteString)
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else {
            throw PromptSkillInstallerError.invalidGitHubURL(url.absoluteString)
        }

        let owner = pathComponents[0]
        let repositoryComponent = pathComponents[1]
        let repository = repositoryComponent.hasSuffix(".git")
            ? String(repositoryComponent.dropLast(4))
            : repositoryComponent
        guard !owner.isEmpty, !repository.isEmpty else {
            throw PromptSkillInstallerError.invalidGitHubURL(url.absoluteString)
        }

        self.originalURL = url
        self.owner = owner
        self.repository = repository
        self.cloneURL = URL(string: "https://github.com/\(owner)/\(repository).git")!
        self.selector = Self.selector(from: Array(pathComponents.dropFirst(2)))
    }

    private static func selector(from pathComponents: [String]) -> Selector? {
        guard let selectorIndex = pathComponents.firstIndex(where: {
            $0 == "tree" || $0 == "blob"
        }) else {
            return nil
        }
        let kind: SelectorKind = pathComponents[selectorIndex] == "blob" ? .blob : .tree
        let components = Array(pathComponents.dropFirst(selectorIndex + 1))
        guard !components.isEmpty else {
            return nil
        }
        return Selector(kind: kind, components: components)
    }
}
