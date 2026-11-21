//
//  MemoryTokenizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 19/10/26.
//
//  Search tokens for lexical retrieval over a bilingual, identifier-heavy
//  journal.
//

import Foundation

/// Produces the lexical tokens BM25, metadata ranking and similarity hints
/// work on. Applied identically to stored text and queries at retrieval time;
/// nothing derived from it is persisted, so the rules can evolve without a
/// graph migration.
///
/// Words are cut on anything that is not a letter or a digit (which already
/// separates `snake_case`, `kebab-case` and dotted names) and additionally on
/// camel-case humps: `AgentCoreSessionRunner` yields the whole lower-cased
/// identifier *and* `agent`, `core`, `session`, `runner`, so an exact
/// identifier still scores on its rare whole token while a prose query reaches
/// it through the segments. Every token, whole identifiers included, is then
/// reduced by a light suffix stemmer covering the English and Italian
/// inflections that recur in the journal — `tests`/`testing` → `test`,
/// `validated`/`validation`/`validazione`/`validata` → `valid`,
/// `memory`/`memories`/`memoria` → `memori`, `stabilize`/`stabilizzati` →
/// `stabiliz` — so the two languages meet on shared Latin roots where the
/// suffixes allow it. It is a heuristic, not a dictionary: consistency between
/// documents and queries is what makes it safe (every text goes through it
/// exactly once), and tokens with digits are never altered.
enum MemoryTokenizer {
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word: [Character] = []
        func flush() {
            guard !word.isEmpty else { return }
            let segments = camelSegments(word)
            if segments.count > 1 {
                // Whole identifier plus each segment, all through the same
                // stemmer so `ZenCODE`, `ZENCODE` and `zencode` coincide.
                tokens.append(stem(String(word).lowercased()))
                for segment in segments {
                    tokens.append(stem(segment.lowercased()))
                }
            } else {
                tokens.append(stem(String(word).lowercased()))
            }
            word.removeAll(keepingCapacity: true)
        }
        for character in text {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Splits a word on camel-case humps: a lower-case letter or digit followed
    /// by an upper-case letter, and the last upper-case letter of an acronym run
    /// that precedes a lower-case letter (`HTTPServer` → `HTTP`, `Server`).
    static func camelSegments(_ word: [Character]) -> [String] {
        guard word.count > 1 else { return [String(word)] }
        var segments: [String] = []
        var start = 0
        for index in 1..<word.count {
            let current = word[index]
            let previous = word[index - 1]
            guard current.isUppercase else { continue }
            let humpAfterLower = previous.isLowercase || previous.isNumber
            let acronymEnd = previous.isUppercase
                && index + 1 < word.count
                && word[index + 1].isLowercase
            if humpAfterLower || acronymEnd {
                segments.append(String(word[start..<index]))
                start = index
            }
        }
        segments.append(String(word[start...]))
        return segments
    }

    /// Suffix rules in matching order; `minimumStem` is the shortest stem a
    /// rule may leave, so short words stay whole.
    private static let suffixRules: [(suffix: String, replacement: String, minimumStem: Int)] = [
        ("azioni", "", 4), ("azione", "", 4),
        ("ations", "", 4), ("ation", "", 4),
        ("zioni", "", 4), ("zione", "", 4),
        ("tions", "", 4), ("tion", "", 4),
        ("ating", "", 4), ("ated", "", 4), ("ates", "", 4), ("ate", "", 4),
        ("ati", "", 4), ("ato", "", 4), ("ata", "", 4),
        ("ings", "", 4), ("ing", "", 4),
        ("ies", "y", 3),
        ("ed", "", 4),
        ("es", "", 3),
        ("s", "", 3),
    ]

    /// `es` is a plural marker only after these endings (`caches`, `fixes`,
    /// `classes`); elsewhere the plain `s` rule applies (`notes` → `note`).
    private static let pluralEsEndings = ["s", "x", "z", "ch", "sh"]

    /// Consonants whose doubling before a stripped suffix is undone
    /// (`committed` → `commit`, `stabilizzati` → `stabiliz`); `l`, `s` and
    /// `f` are left alone because they double in base forms (`call`, `pass`).
    private static let dedoubledConsonants: Set<Character> = ["b", "c", "d", "g", "m", "n", "p", "r", "t", "v", "z"]

    /// Light English/Italian suffix stemmer. Only purely alphabetic tokens of
    /// at least four characters are touched.
    static func stem(_ token: String) -> String {
        guard token.count >= 4, token.allSatisfy(\.isLetter) else { return token }
        var stem = token
        var stripped = false
        for rule in suffixRules where stem.hasSuffix(rule.suffix) {
            let remaining = String(stem.dropLast(rule.suffix.count))
            guard remaining.count >= rule.minimumStem else { continue }
            if rule.suffix == "es", !pluralEsEndings.contains(where: { remaining.hasSuffix($0) }) {
                continue
            }
            stem = remaining + rule.replacement
            stripped = true
            break
        }
        // Final vowel of Italian inflections and silent English `e`
        // (`sessione`/`sessions` → `session`, `release`/`released` → `releas`).
        if stem.count >= 5, let last = stem.last, "aeio".contains(last) {
            stem.removeLast()
        }
        // `memory` and `memoria`/`memorie`/`memories` meet on `memori`.
        if stem.count >= 4, stem.last == "y" {
            stem.removeLast()
            stem.append("i")
        }
        if stripped, stem.count >= 4 {
            let characters = Array(stem)
            let last = characters[characters.count - 1]
            if last == characters[characters.count - 2], dedoubledConsonants.contains(last) {
                stem.removeLast()
            }
        }
        return stem
    }
}
