//
//  MemoryCitedPaths.swift
//  ZenCODE
//
//  Detects repository paths cited by a memory entry that are gone from the
//  current checkout, so the model knows what to verify before trusting it.
//

import Foundation

/// Pure staleness check for the paths a memory entry cites.
///
/// The check is deliberately conservative: a missing note that should have
/// been there costs the model one verification it would have done anyway,
/// while a false note teaches it to distrust correct memory. A token is
/// therefore looked up only when it unmistakably reads as a path of this
/// repository, and everything ambiguous is ignored:
///
/// - the text is split on whitespace and backticks, and each token loses its
///   surrounding punctuation, a `#fragment` (`#L12`, `#L12-L20`, a Markdown
///   anchor), a `:N`, `:N-M` or `:N:M` line suffix, and a leading `./`;
/// - a token without `/`, a URL, a glob, a truncated path (`…`, `...`), a
///   parent-directory reference (`..`), a home-relative or option-like token
///   (`~`, `-` first), and any token with a character outside letters, digits
///   and `_ - . / +` are ignored. `@` is not allowed: `Docs/builder.md@v6.1.1`
///   names a tag of a file, not a file of the checkout;
/// - an absolute token counts only inside the workspace root;
/// - a relative token counts only when its first component is the exact name,
///   capitals included, of an entry of the workspace root (`Sources`, `Docs`,
///   …), and, when the token has more than one component, that entry is a
///   directory. The anchor keeps `feat/x`, `IT/EN` or `lessicale/semantica`
///   from being reported; the exact-name rule keeps `tests/29` (from "186
///   tests/29 suites") from anchoring to `Tests` on a case-insensitive file
///   system; the directory rule keeps `Package.swift/Package.resolved` or
///   `agents.md/architecture.md` (a slash meaning "and/or") from being
///   reported;
/// - a missing path whose last component has no extension is ignored when its
///   parent directory (if it exists) or the workspace root holds an entry with
///   that name before its extension: `Docs/architecture` in "Docs/architecture
///   aggiornati" is prose about `Docs/architecture.md`, and `Docs/CHANGELOG`
///   about the `CHANGELOG.md` of the root.
///
/// The functions only ask the file manager about paths under the workspace
/// root; nothing is cached across calls, because a turn checks a few dozen at
/// most. The names of the root are listed once per call of `missing`.
enum MemoryCitedPaths {
    /// Cited paths that do not exist under `workspaceRoot`, deduplicated and in
    /// order of first appearance, in their normalized textual form (without
    /// punctuation, line suffix, fragment, leading `./` or trailing `/`).
    static func missing(
        in text: String,
        workspaceRoot: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        guard text.contains("/") else {
            return []
        }
        let rootPath = workspaceRoot.standardizedFileURL.path
        let lookup = Lookup(
            rootPath: rootPath,
            rootPrefix: rootPath.hasSuffix("/") ? rootPath : rootPath + "/",
            rootEntries: Set((try? fileManager.contentsOfDirectory(atPath: rootPath)) ?? []),
            fileManager: fileManager
        )
        var seen = Set<String>()
        var missing: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "`" }) {
            guard let candidate = candidate(from: String(token), lookup: lookup),
                  seen.insert(candidate.display).inserted,
                  !fileManager.fileExists(atPath: candidate.path),
                  !isNamedLikeExistingEntry(candidate.path, lookup: lookup) else {
                continue
            }
            missing.append(candidate.display)
        }
        return missing
    }

    /// The one-line note for `paths`, or `nil` when none is missing. At most
    /// `limit` paths are named; the remainder is only counted.
    static func note(forMissing paths: [String], limit: Int = 5) -> String? {
        guard !paths.isEmpty else {
            return nil
        }
        let shown = paths.prefix(max(limit, 1))
        var note = "Not found in the current checkout (verify before relying on this entry): "
        note += shown.map { "`\($0)`" }.joined(separator: ", ")
        if paths.count > shown.count {
            note += " (+\(paths.count - shown.count) more)"
        }
        return note + "."
    }

    // MARK: - Token interpretation

    /// The workspace root as the heuristic sees it.
    private struct Lookup {
        let rootPath: String
        /// `rootPath` with a trailing `/`, to build paths and test containment.
        let rootPrefix: String
        /// Exact names of the entries directly under the root.
        let rootEntries: Set<String>
        let fileManager: FileManager
    }

    /// A token accepted as a path of this workspace.
    private struct Candidate {
        /// Normalized text reported to the model.
        let display: String
        /// Absolute path to look up.
        let path: String
    }

    private static let leadingPunctuation: Set<Character> = ["(", "\"", "'", "[", "<"]
    private static let trailingPunctuation: Set<Character> = [
        ")", "\"", "'", "]", ",", ";", ":", ".", "!", "?", ">"
    ]
    private static let allowedSymbols: Set<Character> = ["_", "-", ".", "/", "+"]
    /// `~` and `@` already fail `isPathCharacter`; `-` is allowed inside a name
    /// but marks an option when it comes first.
    private static let rejectedFirstCharacters: Set<Character> = ["~", "-", "@"]
    /// `:N`, `:N-M` or `:N:M` at the end of a token.
    private static let lineSuffixPattern = #":[0-9]+(-[0-9]+)?(:[0-9]+)?$"#

    private static func candidate(from rawToken: String, lookup: Lookup) -> Candidate? {
        // Checked before the punctuation strip below, which would eat the dots
        // of `...` and leave a truncated path looking whole.
        guard !rawToken.contains("…"), !rawToken.contains("...") else {
            return nil
        }
        var text = Substring(rawToken)
        while let first = text.first, leadingPunctuation.contains(first) {
            text = text.dropFirst()
        }
        while let last = text.last, trailingPunctuation.contains(last) {
            text = text.dropLast()
        }
        var token = String(text)
        if let fragment = token.firstIndex(of: "#") {
            token = String(token[..<fragment])
        }
        if let suffix = token.range(of: lineSuffixPattern, options: .regularExpression) {
            token.removeSubrange(suffix)
        }
        while token.hasPrefix("./") {
            token.removeFirst(2)
        }

        guard token.contains("/"),
              !token.contains("://"),
              let first = token.first,
              !rejectedFirstCharacters.contains(first),
              token.allSatisfy(isPathCharacter) else {
            return nil
        }
        while token.count > 1, token.hasSuffix("/") {
            token.removeLast()
        }

        if token.hasPrefix("/") {
            let standardized = URL(fileURLWithPath: token).standardizedFileURL.path
            guard standardized == lookup.rootPath || standardized.hasPrefix(lookup.rootPrefix) else {
                return nil
            }
            return Candidate(display: token, path: standardized)
        }

        let components = token
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        guard let anchor = components.first,
              !components.contains(".."),
              // Exact, case-sensitive: a case-insensitive file system would
              // let `tests/29` or `docs/X.md` find `Tests` and `Docs`.
              lookup.rootEntries.contains(String(anchor)) else {
            return nil
        }
        if components.count > 1 {
            // `Package.swift/Package.resolved`: a file cannot hold a path.
            var isDirectory: ObjCBool = false
            guard lookup.fileManager.fileExists(
                atPath: lookup.rootPrefix + String(anchor),
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                return nil
            }
        }
        let relative = components.joined(separator: "/")
        return Candidate(display: relative, path: lookup.rootPrefix + relative)
    }

    /// Whether a missing `path` without extension is most likely prose about an
    /// existing file: its parent directory (if present) or the workspace root
    /// holds an entry named like it before the extension.
    private static func isNamedLikeExistingEntry(_ path: String, lookup: Lookup) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.contains(".") else {
            return false
        }
        if lookup.rootEntries.contains(where: { nameWithoutExtension($0) == name }) {
            return true
        }
        let parent = url.deletingLastPathComponent().path
        guard parent != lookup.rootPath,
              let siblings = try? lookup.fileManager.contentsOfDirectory(atPath: parent) else {
            return false
        }
        return siblings.contains { nameWithoutExtension($0) == name }
    }

    /// `architecture.md` → `architecture`; a leading dot (`.github`) is part of
    /// the name, not an extension.
    private static func nameWithoutExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return name
        }
        return String(name[..<dot])
    }

    /// Letters, digits and `_ - . / +`. This also excludes every character the
    /// heuristic names explicitly (`* ? { } [ ] < > $ | \`), `@`, and the
    /// `:`/`,`/`=`/quote residue of prose that merely sits next to a path.
    private static func isPathCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || allowedSymbols.contains(character)
    }
}
