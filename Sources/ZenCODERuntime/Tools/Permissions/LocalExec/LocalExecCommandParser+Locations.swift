//
//  LocalExecCommandParser+Locations.swift
//  ZenCODE
//
//  Locates, in a `local.exec` command string, the characters of every
//  executable the authorization covers, so consent surfaces can emphasize
//  each occurrence. Presentation only: authorization, cache keys, and
//  persistence keep using `authorizationAnalysis(in:)`.
//

import Foundation

extension LocalExecCommandParser {
    // MARK: - Located text

    /// Text derived from a command string together with the position each of
    /// its characters comes from.
    ///
    /// `origins` has one element per `Character` of `text`: the index of the
    /// root command's `Character` it was copied from, or `nil` for synthetic
    /// text (such as the `case _ in ` header the segmenter adds). Locations
    /// only drive emphasis, so a mismatch fails soft: when `origins` does not
    /// have one element per character, every origin is `nil`.
    struct LocatedText: Equatable, Sendable {
        let text: String
        let origins: [Int?]

        init(text: String, origins: [Int?]) {
            self.text = text
            let count = text.count
            self.origins = origins.count == count
                ? origins
                : Array(repeating: nil, count: count)
        }

        /// A root command: each character is located at its own index.
        init(root command: String) {
            self.init(text: command, origins: (0..<command.count).map(Optional.some))
        }

        /// Composes the origins with those of the text this one was derived
        /// from: an origin local to `parentOrigins` becomes the parent's
        /// origin. Out-of-range local origins become `nil`.
        func mapped(through parentOrigins: [Int?]) -> LocatedText {
            LocatedText(text: text, origins: origins.map { origin in
                guard let origin, parentOrigins.indices.contains(origin) else {
                    return nil
                }
                return parentOrigins[origin]
            })
        }

        /// The text of `trimmingCharacters(in: .whitespacesAndNewlines)`, with
        /// the origins of the characters it keeps. When the trimmed text is not
        /// a whole-character slice of the original (a whitespace scalar inside
        /// a grapheme cluster), the text stays exact and the origins are `nil`.
        func trimmingWhitespacesAndNewlines() -> LocatedText {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let characters = Array(text)
            func isTrimmable(_ character: Character) -> Bool {
                character.unicodeScalars.allSatisfy {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                }
            }
            var start = 0
            while start < characters.count, isTrimmable(characters[start]) {
                start += 1
            }
            var end = characters.count
            while end > start, isTrimmable(characters[end - 1]) {
                end -= 1
            }
            guard characters[start..<end].elementsEqual(trimmed) else {
                return LocatedText(text: trimmed, origins: [])
            }
            return LocatedText(text: trimmed, origins: Array(origins[start..<end]))
        }
    }

    /// Accumulates characters with their origins, for the scanners that copy
    /// part of their input.
    struct LocatedTextBuilder {
        private(set) var text = ""
        private(set) var origins: [Int?] = []

        mutating func append(_ character: Character, origin: Int?) {
            text.append(character)
            origins.append(origin)
        }

        var located: LocatedText {
            LocatedText(text: text, origins: origins)
        }
    }

    /// A shell word with, for each `Character` of its value, the index of the
    /// tokenized segment's character it was copied from. Quote characters are
    /// not part of the value, so they have no origin.
    struct LocatedShellWord: Equatable {
        let word: ShellWord
        let origins: [Int]

        /// The value with its origins, validated by ``LocatedText``.
        var locatedValue: LocatedText {
            LocatedText(text: word.value, origins: origins.map(Optional.some))
        }
    }

    // MARK: - Executable positions

    /// One authorization candidate with the root-command positions of every
    /// occurrence of its executable name. Sentinels and unresolved segments
    /// have no positions.
    struct LocatedCandidate: Equatable {
        let identity: String
        var positions: [Int]
    }

    /// Returns the indices (in `Array(command)`) of the characters that name
    /// an executable the authorization of `command` covers, sorted and
    /// unique: every occurrence of the identities `authorizationCandidates(in:)`
    /// produces, never built-ins, decorative `echo`/`printf`, wrappers,
    /// assignments, keywords, arguments, or quoted heredoc bodies. For a shell
    /// `-c` invocation the commands of the payload are located, not the shell.
    static func executablePositions(in command: String) -> [Int] {
        let candidates = collectLocatedCandidates(in: LocatedText(root: command), depth: 0)
        return Array(Set(candidates.flatMap(\.positions))).sorted()
    }

    /// Mirrors `collectAuthorizationCandidates(in:depth:)` step by step (same
    /// depth, candidate-count, and substitution limits, same sentinels), while
    /// keeping the positions of every occurrence of each identity.
    static func collectLocatedCandidates(
        in command: LocatedText,
        depth: Int
    ) -> [LocatedCandidate] {
        guard depth < Self.maxCandidateDepth else {
            // Beyond the depth limit nothing is inventoried: the sentinel
            // stands for the rest and locates nothing.
            let trimmed = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [LocatedCandidate(identity: Self.analysisDepthLimitIdentity, positions: [])]
        }

        let segments = locatedCommandSegments(in: command.text)
            .map { $0.mapped(through: command.origins) }
        guard !segments.isEmpty else {
            return []
        }

        var indexByIdentity: [String: Int] = [:]
        var candidates: [LocatedCandidate] = []
        var hitLimit = false

        func add(_ identity: String, positions: [Int]) {
            if candidates.count >= Self.maxCandidateCount {
                hitLimit = true
                return
            }
            if let existing = indexByIdentity[identity] {
                candidates[existing].positions.append(contentsOf: positions)
            } else {
                indexByIdentity[identity] = candidates.count
                candidates.append(LocatedCandidate(identity: identity, positions: positions))
            }
        }

        for segment in segments {
            if candidates.count >= Self.maxCandidateCount {
                hitLimit = true
                break
            }
            collectLocatedCandidates(from: segment, depth: depth, into: add)
        }

        for body in locatedUnquotedHeredocBodies(in: command.text) {
            if candidates.count >= Self.maxCandidateCount {
                hitLimit = true
                break
            }
            let located = body.mapped(through: command.origins)
            let substitutions = locatedCommandSubstitutionContents(in: located.text)
                .map { $0.mapped(through: located.origins) }
            if substitutions.count > Self.maxSubstitutionCount {
                add(Self.tooManyCommandsIdentity, positions: [])
            }
            for content in substitutions.prefix(Self.maxSubstitutionCount) {
                for candidate in collectLocatedCandidates(in: content, depth: depth + 1) {
                    add(candidate.identity, positions: candidate.positions)
                }
            }
        }

        if hitLimit, indexByIdentity[Self.tooManyCommandsIdentity] == nil {
            candidates.append(LocatedCandidate(identity: Self.tooManyCommandsIdentity, positions: []))
        }

        return candidates
    }

    /// Mirrors `collectCandidates(from:depth:into:)` for one located segment.
    static func collectLocatedCandidates(
        from segment: LocatedText,
        depth: Int,
        into add: (String, _ positions: [Int]) -> Void
    ) {
        let match = executableIdentityMatch(for: segment.text)
        switch match.identity {
        case .skip:
            extractLocatedNestedCandidates(from: segment, depth: depth, into: add)

        case .executable(let name):
            if let payload = locatedShellDashCPayload(for: segment.text) {
                let located = payload.mapped(through: segment.origins)
                for candidate in collectLocatedCandidates(in: located, depth: depth + 1) {
                    add(candidate.identity, candidate.positions)
                }
                extractLocatedNestedCandidates(from: segment, depth: depth, into: add)
                return
            }

            if isDecorativeEchoPrintf(identity: name, segment: segment.text) {
                extractLocatedNestedCandidates(from: segment, depth: depth, into: add)
                return
            }

            let positions = match.positions.compactMap { position in
                segment.origins.indices.contains(position) ? segment.origins[position] : nil
            }
            add(name, positions)
            extractLocatedNestedCandidates(from: segment, depth: depth, into: add)

        case .unresolved(let raw):
            // Authorized by its raw text, without recursion: nothing to locate.
            add(raw, [])
        }
    }

    /// Mirrors `extractNestedCandidates(from:depth:into:)`.
    static func extractLocatedNestedCandidates(
        from segment: LocatedText,
        depth: Int,
        into add: (String, _ positions: [Int]) -> Void
    ) {
        let substitutions = locatedCommandSubstitutionContents(in: segment.text)
            .map { $0.mapped(through: segment.origins) }
        if substitutions.count > Self.maxSubstitutionCount {
            add(Self.tooManyCommandsIdentity, [])
        }
        for content in substitutions.prefix(Self.maxSubstitutionCount) {
            for candidate in collectLocatedCandidates(in: content, depth: depth + 1) {
                add(candidate.identity, candidate.positions)
            }
        }
    }
}
