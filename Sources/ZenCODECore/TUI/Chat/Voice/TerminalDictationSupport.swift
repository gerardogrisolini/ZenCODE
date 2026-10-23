//
//  TerminalDictationSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 23/10/26.
//

import Foundation
import Synchronization

/// The voice experience the interactive terminal runs.
enum TerminalVoiceMode: Sendable, Equatable {
    case off
    /// A live OpenAI realtime conversation.
    case realtime
    /// Local speech recognition into ordinary prompts, with spoken answers.
    case dictation

    /// Voice mode belongs to the Organizer profile only: a realtime model gets
    /// the realtime conversation, any other model gets dictation.
    static func resolve(isOrganizer: Bool, isRealtimeModel: Bool) -> Self {
        guard isOrganizer else {
            return .off
        }
        return isRealtimeModel ? .realtime : .dictation
    }
}

/// Splits continuous speech recognition into utterances on a silence gap.
struct TerminalDictationSegmenter: Sendable {
    static let defaultSilence = Duration.milliseconds(1_200)

    let silence: Duration
    private(set) var text = ""
    private var lastChange: ContinuousClock.Instant?

    init(silence: Duration = Self.defaultSilence) {
        self.silence = silence
    }

    var hasPendingText: Bool {
        !text.isEmpty
    }

    /// Records the latest recognized text of the current utterance. The
    /// silence gap restarts only when the text actually changes.
    mutating func observe(_ recognized: String, at now: ContinuousClock.Instant) {
        let normalized = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != text else {
            return
        }
        text = normalized
        lastChange = normalized.isEmpty ? nil : now
    }

    func isUtteranceComplete(at now: ContinuousClock.Instant) -> Bool {
        guard !text.isEmpty, let lastChange else {
            return false
        }
        return lastChange.duration(to: now) >= silence
    }

    /// Returns and clears the current utterance, if any.
    mutating func takeUtterance() -> String? {
        defer {
            reset()
        }
        return text.isEmpty ? nil : text
    }

    mutating func reset() {
        text = ""
        lastChange = nil
    }
}

/// Residual-echo filter for speech recognized while (or just after) the
/// assistant speaks. System echo cancellation removes most of the assistant's
/// voice from the microphone; this rejects what leaks through, so the
/// assistant neither interrupts itself nor answers its own words.
enum TerminalVoiceEchoGuard {
    /// How long after speech ended a recognition can still be its echo.
    static let tail = Duration.milliseconds(1_500)

    /// `true` when at least 80% of the recognized words occur in the text
    /// being spoken.
    static func isLikelyEcho(_ recognized: String, of spoken: String) -> Bool {
        let heard = words(in: recognized)
        guard !heard.isEmpty else {
            return false
        }
        let spokenWords = Set(words(in: spoken))
        guard !spokenWords.isEmpty else {
            return false
        }
        let matched = heard.filter(spokenWords.contains).count
        return matched * 5 >= heard.count * 4
    }

    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// Lock-protected speaking state shared by the speech synthesizer callback,
/// playback completions and the dictation controller.
final class TerminalVoiceSpeechState: Sendable {
    /// Synthesis that produced no buffer for this long is treated as finished,
    /// even when the synthesizer never delivered its terminal buffer.
    static let synthesisIdleTimeout = Duration.seconds(2)

    private struct State {
        var generation: UInt64 = 0
        var pendingBuffers = 0
        var isSynthesizing = false
        var text = ""
        var lastActivity: ContinuousClock.Instant?
        var finishedAt: ContinuousClock.Instant?
    }

    private let state = Mutex(State())

    /// Starts a new utterance and returns its generation.
    func begin(text: String, at now: ContinuousClock.Instant = .now) -> UInt64 {
        state.withLock { state in
            state.generation &+= 1
            state.pendingBuffers = 0
            state.isSynthesizing = true
            state.text = text
            state.lastActivity = now
            state.finishedAt = nil
            return state.generation
        }
    }

    /// Records a scheduled buffer. `false` for a superseded utterance.
    func bufferScheduled(generation: UInt64, at now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { state in
            guard generation == state.generation, state.finishedAt == nil else {
                return false
            }
            state.pendingBuffers += 1
            state.lastActivity = now
            return true
        }
    }

    func bufferPlayed(generation: UInt64, at now: ContinuousClock.Instant = .now) {
        state.withLock { state in
            guard generation == state.generation, state.pendingBuffers > 0 else {
                return
            }
            state.pendingBuffers -= 1
            state.lastActivity = now
            Self.finishIfDone(&state, at: now)
        }
    }

    func synthesisFinished(generation: UInt64, at now: ContinuousClock.Instant = .now) {
        state.withLock { state in
            guard generation == state.generation else {
                return
            }
            state.isSynthesizing = false
            Self.finishIfDone(&state, at: now)
        }
    }

    /// Stops the current utterance; its late callbacks become stale.
    func cancel(at now: ContinuousClock.Instant = .now) {
        state.withLock { state in
            let wasSpeaking = Self.isSpeaking(state, at: now)
            state.generation &+= 1
            state.pendingBuffers = 0
            state.isSynthesizing = false
            if wasSpeaking {
                state.finishedAt = now
            }
        }
    }

    func isSpeaking(at now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { Self.isSpeaking($0, at: now) }
    }

    /// The text being spoken, or spoken within the echo tail.
    func echoReference(at now: ContinuousClock.Instant = .now) -> String? {
        state.withLock { state in
            guard !state.text.isEmpty else {
                return nil
            }
            if Self.isSpeaking(state, at: now) {
                return state.text
            }
            let ended = state.finishedAt ?? state.lastActivity
            guard let ended, ended.duration(to: now) < TerminalVoiceEchoGuard.tail else {
                return nil
            }
            return state.text
        }
    }

    private static func isSpeaking(_ state: State, at now: ContinuousClock.Instant) -> Bool {
        if state.pendingBuffers > 0 {
            return true
        }
        guard state.isSynthesizing, state.finishedAt == nil else {
            return false
        }
        guard let lastActivity = state.lastActivity else {
            return true
        }
        return lastActivity.duration(to: now) < synthesisIdleTimeout
    }

    private static func finishIfDone(_ state: inout State, at now: ContinuousClock.Instant) {
        if !state.isSynthesizing, state.pendingBuffers == 0, state.finishedAt == nil {
            state.finishedAt = now
        }
    }
}

/// Plain spoken text from an assistant Markdown answer.
enum TerminalVoiceSpeechText {
    static func speakable(fromMarkdown markdown: String, languageCode: String?) -> String {
        var sentences: [String] = []
        var isInsideFence = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if !isInsideFence {
                    sentences.append(codeBlockNotice(languageCode: languageCode))
                }
                isInsideFence.toggle()
                continue
            }
            guard !isInsideFence else {
                continue
            }
            if let sentence = spokenSentence(fromLine: line) {
                sentences.append(sentence)
            }
        }
        return sentences.joined(separator: " ")
    }

    static func codeBlockNotice(languageCode: String?) -> String {
        let code = languageCode?.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        return codeBlockNotices[code] ?? codeBlockNotices["en"]!
    }

    private static let codeBlockNotices: [String: String] = [
        "en": "Code block omitted.",
        "it": "Blocco di codice omesso.",
        "es": "Bloque de código omitido.",
        "fr": "Bloc de code omis.",
        "de": "Codeblock ausgelassen.",
        "pt": "Bloco de código omitido."
    ]

    private static func spokenSentence(fromLine line: String) -> String? {
        guard !line.isEmpty, !isHorizontalRuleOrTableSeparator(line) else {
            return nil
        }
        var text = line
        text = replacing(#"^#{1,6}\s+"#, in: text, with: "")
        text = replacing(#"^>\s?"#, in: text, with: "")
        text = replacing(#"^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, in: text, with: "")
        if text.hasPrefix("|") || text.hasSuffix("|") {
            text = text
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        text = replacing(#"!\[([^\]]*)\]\([^)]*\)"#, in: text, with: "$1")
        text = replacing(#"\[([^\]]+)\]\([^)]*\)"#, in: text, with: "$1")
        text = replacing(#"`([^`]*)`"#, in: text, with: "$1")
        text = replacing(#"https?://([^/\s)]+)[^\s)]*"#, in: text, with: "$1")
        text = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "*", with: "")
        text = replacing(#"\s+"#, in: text, with: " ").trimmingCharacters(in: .whitespaces)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        if let last = text.last, !".!?:;,…".contains(last) {
            text.append(".")
        }
        return text
    }

    private static func isHorizontalRuleOrTableSeparator(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else {
            return true
        }
        return compact.allSatisfy { "-*_|:=".contains($0) }
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

/// Language of the dictation recognizer and the spoken answers.
enum TerminalVoiceLanguage {
    /// The configured voice language, else the response language, else the
    /// system language, else English.
    static func resolvedCode(
        voiceLanguage: String?,
        responseLanguage: String?,
        systemLanguage: String?
    ) -> String {
        for candidate in [voiceLanguage, responseLanguage, systemLanguage] {
            if let code = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !code.isEmpty {
                return code
            }
        }
        return "en"
    }
}
