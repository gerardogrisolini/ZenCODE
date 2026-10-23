//
//  TerminalDictationSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 23/10/26.
//

import Foundation
import Synchronization

/// A `/voice` subcommand. Voice mode runs with any agent and belongs to the
/// current TUI session only: it is never persisted.
enum TerminalVoiceCommandAction: Sendable, Equatable {
    /// Bare `/voice`: pauses a listening voice mode, resumes a paused one.
    case togglePause
    case turnOn
    case turnOff
    case pause
    case resume
    case usage

    static let usageMessage = "Usage: /voice [on|off|pause|resume]\n"

    init(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "":
            self = .togglePause
        case "on":
            self = .turnOn
        case "off":
            self = .turnOff
        case "pause":
            self = .pause
        case "resume":
            self = .resume
        default:
            self = .usage
        }
    }
}

/// Splits continuous speech recognition into utterances on a silence gap.
struct TerminalDictationSegmenter: Sendable {
    static let defaultSilence = Duration.milliseconds(5_000)

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
        hasStableText(for: silence, at: now)
    }

    /// `true` when there is text and it has not changed for `duration`.
    func hasStableText(for duration: Duration, at now: ContinuousClock.Instant) -> Bool {
        guard !text.isEmpty, let lastChange else {
            return false
        }
        return lastChange.duration(to: now) >= duration
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

    /// `true` when `recognized` must be dropped as the assistant's own voice.
    /// Once the assistant stopped speaking, a bare yes or no is the operator
    /// answering a spoken question ("Do you want to reply?") even when the
    /// message just read contained that word: the echo of a sentence is
    /// recognized as that sentence, not as one of its words alone.
    static func shouldDrop(_ recognized: String, spokenReference: String, isSpeaking: Bool) -> Bool {
        guard isLikelyEcho(recognized, of: spokenReference) else {
            return false
        }
        return isSpeaking || TerminalVoiceChatPhrases.affirmation(in: recognized) == nil
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
    /// A synthesizer may take longer than that to deliver its first buffer
    /// (a premium voice loading): until then the utterance counts as speaking
    /// for this long, so a slow start is not mistaken for the end of speech.
    static let synthesisStartTimeout = Duration.seconds(10)

    private struct State {
        var generation: UInt64 = 0
        var pendingBuffers = 0
        var isSynthesizing = false
        var didScheduleBuffer = false
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
            state.didScheduleBuffer = false
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
            state.didScheduleBuffer = true
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
        let timeout = state.didScheduleBuffer ? synthesisIdleTimeout : synthesisStartTimeout
        return lastActivity.duration(to: now) < timeout
    }

    private static func finishIfDone(_ state: inout State, at now: ContinuousClock.Instant) {
        if !state.isSynthesizing, state.pendingBuffers == 0, state.finishedAt == nil {
            state.finishedAt = now
        }
    }
}

/// Keyword send mode, shared by both platforms: recognized speech waits until
/// a segment ends with the keyword, then everything collected is sent as one
/// utterance. Silence never sends. While the live-chat dialogue awaits a yes
/// or no, a bare answer is sent at once without the keyword.
struct TerminalVoiceKeywordCollector: Sendable {
    enum Outcome: Sendable, Equatable {
        /// Send this utterance.
        case send(String)
        /// Kept until the keyword is said.
        case collected
        /// Nothing to do: empty speech, or the keyword alone with nothing
        /// collected.
        case nothing
    }

    let keyword: TerminalVoiceSendKeyword
    /// Speech from earlier segments, waiting for the keyword.
    private(set) var pending = ""

    init(keyword: TerminalVoiceSendKeyword) {
        self.keyword = keyword
    }

    var hasPendingText: Bool {
        !pending.isEmpty
    }

    /// What `receive` would do with `speech`, without changing anything.
    func peek(_ speech: String, awaitingShortAnswer: Bool) -> Outcome {
        var copy = self
        return copy.receive(speech, awaitingShortAnswer: awaitingShortAnswer)
    }

    /// Handles one finished segment of speech.
    mutating func receive(_ speech: String, awaitingShortAnswer: Bool) -> Outcome {
        let trimmed = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .nothing
        }
        if awaitingShortAnswer, pending.isEmpty,
           TerminalVoiceChatPhrases.affirmation(in: trimmed) != nil {
            return .send(trimmed)
        }
        if let utterance = keyword.utteranceToSend(pending: pending, speech: trimmed) {
            pending = ""
            return utterance.isEmpty ? .nothing : .send(utterance)
        }
        pending = TerminalVoiceSendKeyword.joined(pending, trimmed)
        return .collected
    }

    mutating func reset() {
        pending = ""
    }
}

/// Plain spoken text from an assistant Markdown answer.
enum TerminalVoiceSpeechText {
    /// Spoken answers longer than this, about 40 seconds of reading, keep only
    /// their final sentences: the end of an answer usually holds the outcome
    /// and the questions on how to continue. The terminal still shows the
    /// whole answer.
    static let maximumSpokenCharacters = 600

    /// The text read aloud for an answer: its plain spoken text, or, past
    /// `maximumCharacters` (nil never shortens), a short notice followed by
    /// the final sentences that fit the limit.
    static func spokenAnswer(
        fromMarkdown markdown: String,
        languageCode: String?,
        maximumCharacters: Int? = maximumSpokenCharacters
    ) -> String {
        let lines = speakableLines(fromMarkdown: markdown, languageCode: languageCode)
        let text = lines.joined(separator: " ")
        guard let maximumCharacters, text.count > maximumCharacters else {
            return text
        }
        let tail = finalSentences(of: lines, maximumCharacters: maximumCharacters)
        return longAnswerNotice(languageCode: languageCode) + " " + tail
    }

    static func speakable(fromMarkdown markdown: String, languageCode: String?) -> String {
        speakableLines(fromMarkdown: markdown, languageCode: languageCode).joined(separator: " ")
    }

    private static func speakableLines(fromMarkdown markdown: String, languageCode: String?) -> [String] {
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
        return sentences
    }

    /// The last whole sentences of `lines` within `maximumCharacters`. When
    /// even the last sentence is longer, its end is kept from a word boundary.
    private static func finalSentences(of lines: [String], maximumCharacters: Int) -> String {
        let sentences = lines.flatMap(splitSentences(in:))
        var kept: [String] = []
        var length = 0
        for sentence in sentences.reversed() {
            let added = kept.isEmpty ? sentence.count : sentence.count + 1
            guard length + added <= maximumCharacters else {
                break
            }
            kept.insert(sentence, at: 0)
            length += added
        }
        if !kept.isEmpty {
            return kept.joined(separator: " ")
        }
        guard let last = sentences.last else {
            return ""
        }
        let suffix = last.suffix(maximumCharacters)
        guard let space = suffix.firstIndex(where: \.isWhitespace) else {
            return String(suffix)
        }
        let fromWord = suffix[space...].trimmingCharacters(in: .whitespaces)
        return fromWord.isEmpty ? String(suffix) : fromWord
    }

    /// Splits a spoken line after `.`, `!`, `?` or `…` followed by whitespace.
    private static func splitSentences(in line: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in line {
            if character.isWhitespace, let previous, ".!?…".contains(previous) {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        let sentence = current.trimmingCharacters(in: .whitespaces)
        if !sentence.isEmpty {
            sentences.append(sentence)
        }
        return sentences
    }

    static func codeBlockNotice(languageCode: String?) -> String {
        localized(codeBlockNotices, languageCode: languageCode)
    }

    static func longAnswerNotice(languageCode: String?) -> String {
        localized(longAnswerNotices, languageCode: languageCode)
    }

    /// The notice for the language code's primary subtag, else English.
    static func localized(_ notices: [String: String], languageCode: String?) -> String {
        let code = languageCode?.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        return notices[code] ?? notices["en"]!
    }

    private static let longAnswerNotices: [String: String] = [
        "en": "Long answer, reading only the end.",
        "it": "Risposta lunga, leggo solo la parte finale.",
        "es": "Respuesta larga, leo solo la parte final.",
        "fr": "Réponse longue, je ne lis que la fin.",
        "de": "Lange Antwort, ich lese nur den Schluss.",
        "pt": "Resposta longa, leio só a parte final."
    ]

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
