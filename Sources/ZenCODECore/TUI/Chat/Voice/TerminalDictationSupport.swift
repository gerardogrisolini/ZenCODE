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
///
/// The recognizer reports the segment in progress with volatile results and
/// closes it with a final result after a short pause; the following results
/// hold only the words said after it. The segmenter therefore keeps the
/// segments already closed in the current recognition session plus the one in
/// progress, and its `text` is all of them, one per line.
struct TerminalDictationSegmenter: Sendable {
    static let defaultSilence = Duration.milliseconds(5_000)
    /// Separates the speech segments of one utterance: what is said after a
    /// short pause continues on a new line.
    static let segmentSeparator = "\n"

    let silence: Duration
    /// Segments the recognizer closed in the current session, trimmed and not
    /// empty.
    private var finishedSegments: [String] = []
    /// The segment being recognized, trimmed.
    private var currentSegment = ""
    private var lastChange: ContinuousClock.Instant?

    init(silence: Duration = Self.defaultSilence) {
        self.silence = silence
    }

    /// The finished segments and the one in progress, each trimmed, empty ones
    /// skipped, joined by `segmentSeparator`.
    var text: String {
        (finishedSegments + [currentSegment])
            .filter { !$0.isEmpty }
            .joined(separator: Self.segmentSeparator)
    }

    var hasPendingText: Bool {
        !finishedSegments.isEmpty || !currentSegment.isEmpty
    }

    /// `true` when there is text and its last segment is closed: nothing is
    /// being recognized after the last final result.
    var endsWithClosedSegment: Bool {
        !finishedSegments.isEmpty && currentSegment.isEmpty
    }

    /// Records the latest recognized text of the segment in progress; earlier
    /// segments stay. `endsSegment` marks a result that closes the segment:
    /// the recognition of the next one restarts from nothing.
    ///
    /// The silence gap restarts only when the combined `text` actually
    /// changes, so closing a segment, or an empty result right after it, neither
    /// clears the text nor moves the gap. A closing result that arrives while
    /// no segment is in progress and repeats the words of the last finished
    /// one (a repeated final result) is ignored. A closing result without
    /// words closes the segment in progress as it is.
    mutating func observe(_ recognized: String, at now: ContinuousClock.Instant, endsSegment: Bool = false) {
        let previous = text
        let normalized = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        if endsSegment {
            if currentSegment.isEmpty, let last = finishedSegments.last, Self.hasSameWords(normalized, last) {
                return
            }
            if !normalized.isEmpty {
                currentSegment = normalized
            }
            if !currentSegment.isEmpty {
                finishedSegments.append(currentSegment)
                currentSegment = ""
            }
        } else {
            currentSegment = normalized
        }
        let combined = text
        guard combined != previous else {
            return
        }
        lastChange = combined.isEmpty ? nil : now
    }

    func isUtteranceComplete(at now: ContinuousClock.Instant) -> Bool {
        hasStableText(for: silence, at: now)
    }

    /// `true` when there is text and it has not changed for `duration`.
    func hasStableText(for duration: Duration, at now: ContinuousClock.Instant) -> Bool {
        guard hasPendingText, let lastChange else {
            return false
        }
        return lastChange.duration(to: now) >= duration
    }

    /// Returns and clears the current utterance, all its segments, if any.
    mutating func takeUtterance() -> String? {
        let utterance = text
        reset()
        return utterance.isEmpty ? nil : utterance
    }

    /// Forgets every segment, finished and in progress.
    mutating func reset() {
        finishedSegments = []
        currentSegment = ""
        lastChange = nil
    }

    /// Whether both texts hold the same words, ignoring case, accents and
    /// punctuation.
    private static func hasSameWords(_ lhs: String, _ rhs: String) -> Bool {
        let words = TerminalVoiceEchoGuard.words(in: lhs)
        return !words.isEmpty && words == TerminalVoiceEchoGuard.words(in: rhs)
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
        /// The keyword was said: send everything collected before it. Empty
        /// for the keyword alone with nothing collected, which sends the
        /// typed draft.
        case send(String)
        /// A bare yes or no the live-chat dialogue awaits: send it alone.
        case answer(String)
        /// Kept until the keyword is said.
        case collected
        /// Nothing to do: empty speech.
        case nothing

        /// Whether the outcome sends something.
        var sends: Bool {
            switch self {
            case .send, .answer:
                return true
            case .collected, .nothing:
                return false
            }
        }
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
        if pending.isEmpty,
           TerminalVoiceUtterance.isAwaitedAnswer(trimmed, awaitingShortAnswer: awaitingShortAnswer) {
            return .answer(trimmed)
        }
        if let utterance = keyword.utteranceToSend(pending: pending, speech: trimmed) {
            pending = ""
            return .send(utterance)
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
    /// The text read aloud for an answer: its plain spoken text, however long.
    /// An answer is never shortened; code blocks become a short notice.
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
        localized(codeBlockNotices, languageCode: languageCode)
    }

    /// The notice for the language code's primary subtag, else English.
    static func localized(_ notices: [String: String], languageCode: String?) -> String {
        let code = languageCode?.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        return notices[code] ?? notices["en"]!
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
