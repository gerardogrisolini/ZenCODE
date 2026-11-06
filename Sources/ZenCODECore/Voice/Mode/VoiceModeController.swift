//
//  VoiceModeController.swift
//  ZenCODE
//
//  The platform-neutral contract of voice mode. macOS runs local
//  dictation with Apple speech frameworks; Linux runs the downloaded
//  sherpa-onnx programs. Both turn utterances into ordinary prompts and read
//  final answers aloud; audio is never persisted.
//

import Foundation

/// What a voice controller recognized and sends.
public enum VoiceModeUtterance: Sendable, Equatable {
    /// The final words of dictation `id`. The channel sends them after the
    /// typed draft, as one prompt, unless an edit already turned the
    /// dictation into ordinary draft text. The text may be empty: the send
    /// keyword said alone sends the typed draft.
    case dictation(id: UInt64, text: String)
    /// A bare yes or no the live-chat dialogue awaits, sent alone: the typed
    /// draft stays as it is.
    case answer(String)

    /// Whether `speech` is a bare yes or no while the live-chat dialogue
    /// awaits one.
    static func isAwaitedAnswer(_ speech: String, awaitingShortAnswer: Bool) -> Bool {
        awaitingShortAnswer && VoiceChatPhrases.affirmation(in: speech) != nil
    }
}

/// Where a voice controller reports what happens. Only ``VoiceModeSession``
/// builds them, and hands them to the controller it creates; a test
/// controller calls them to pretend it heard or read something.
public struct VoiceModeCallbacks: Sendable {
    /// A notice of the controller, e.g. that it listens; ends with a newline.
    public let systemMessage: @Sendable (String) async -> Void
    /// A failure of the controller; ends with a newline.
    public let failureMessage: @Sendable (String) async -> Void
    public let utteranceRecognized: @Sendable (VoiceModeUtterance) async -> Void
    /// The speech recognized but not sent yet for dictation `id`, shown live
    /// at the end of the prompt draft; an empty text removes the preview.
    public let dictationChanged: @Sendable (UInt64, String) async -> Void
    /// The controller started (`true`) or stopped (`false`) reading an
    /// answer aloud, so `Esc` can stop the reading.
    public let speakingChanged: @Sendable (Bool) async -> Void

    init(
        systemMessage: @escaping @Sendable (String) async -> Void,
        failureMessage: @escaping @Sendable (String) async -> Void,
        utteranceRecognized: @escaping @Sendable (VoiceModeUtterance) async -> Void,
        dictationChanged: @escaping @Sendable (UInt64, String) async -> Void,
        speakingChanged: @escaping @Sendable (Bool) async -> Void
    ) {
        self.systemMessage = systemMessage
        self.failureMessage = failureMessage
        self.utteranceRecognized = utteranceRecognized
        self.dictationChanged = dictationChanged
        self.speakingChanged = speakingChanged
    }
}

/// How a text handed to ``VoiceModeController/speak(_:rendering:)`` is
/// turned into speech.
public enum VoiceModeSpeechRendering: Sendable, Equatable {
    /// An assistant answer: Markdown becomes plain text and the whole answer
    /// is read, however long.
    case answer
    /// Already-spoken text, read whole and unchanged: the announcements and
    /// questions of the live chat.
    case plainText
}

/// One platform's voice mode: dictation into ordinary prompts and spoken
/// answers. ``VoiceModeSession`` drives it; a host app implements it only
/// to give the session a test controller (see
/// ``VoiceModeSession/init(makeController:)``), which records and plays
/// nothing.
public protocol VoiceModeController: Actor {
    /// `false` once the controller failed or was stopped; `/voice on` then
    /// starts a new one.
    var isActive: Bool { get }
    /// A paused voice mode neither listens nor reads answers aloud.
    var isPaused: Bool { get }
    /// `true` while something is being read aloud.
    var isSpeaking: Bool { get }
    /// The language answers are read in, e.g. `it`. Fixed for the
    /// controller's lifetime, so it is readable without an actor hop.
    nonisolated var languageCode: String { get }

    /// Starts listening. It may wait on the system permission prompts or on
    /// loading the speech models; the session never awaits it on the
    /// channel's path.
    func start() async
    func stop() async
    /// Reads `text` aloud, replacing anything still being read. Returns
    /// `false` when nothing was started: voice mode not listening or paused,
    /// no synthesizer, or nothing left to say.
    @discardableResult
    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool
    /// Stops the answer being read, e.g. after `Esc`.
    func interruptPlayback() async
    /// Returns `false` when already in the requested state.
    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool
    /// Whether the live-chat dialogue awaits a yes or no. A bare answer is
    /// then sent alone, in either send mode and without the keyword.
    func setAwaitingShortAnswer(_ awaiting: Bool) async
    /// An edit turned dictation `id` into ordinary draft text: forget the
    /// speech collected for it and start a new dictation, without reporting
    /// a preview (the channel already ended it). Nothing happens when the
    /// controller has moved past `id`.
    ///
    /// Dictation ids start at 1 and advance after every dictation sent and
    /// every discard, so the channel can ignore stale previews and sends.
    func discardDictation(through id: UInt64) async
}

extension VoiceModeController {
    /// Reads a final answer aloud.
    @discardableResult
    func speak(_ response: String) async -> Bool {
        await speak(response, rendering: .answer)
    }
}

/// The voice mode options chosen in `/setup` > Voice mode, resolved against
/// the built-in defaults; shared by both platforms.
struct VoiceModeOptions: Sendable, Equatable {
    static let defaultUtteranceSilence = VoiceDictationSegmenter.defaultSilence
    /// In keyword mode the Linux recognizer still splits speech on silence; a
    /// short gap makes the keyword at the end of a segment take effect soon.
    static let keywordRecognizerSilenceSeconds = 1

    /// How an utterance is sent.
    enum SendMode: Sendable, Equatable {
        /// After `utteranceSilence`.
        case pause
        /// Once the speech ends with the keyword; silence never sends.
        case keyword(VoiceModeSendKeyword)
    }

    /// Silence that ends an utterance in `.pause` mode.
    let utteranceSilence: Duration
    let sendMode: SendMode

    init(
        utteranceSilence: Duration = Self.defaultUtteranceSilence,
        sendMode: SendMode = .pause
    ) {
        self.utteranceSilence = utteranceSilence
        self.sendMode = sendMode
    }

    /// The saved options: a missing value keeps its default, and keyword mode
    /// without a usable keyword is pause mode.
    init(voice: AgentVoiceSettingsManifest?) {
        let keyword = voice?.sendKeyword.flatMap(VoiceModeSendKeyword.init)
        self.init(
            utteranceSilence: voice?.utteranceSilenceSeconds.map { .seconds($0) }
                ?? Self.defaultUtteranceSilence,
            sendMode: voice?.sendMode == .keyword ? keyword.map(SendMode.keyword) ?? .pause : .pause
        )
    }

    /// Whole seconds of silence, as the sherpa-onnx recognizer takes them.
    var utteranceSilenceSeconds: Int {
        Int(utteranceSilence.components.seconds)
    }

    /// The silence the Linux recognizer splits speech on.
    var recognizerSilenceSeconds: Int {
        switch sendMode {
        case .pause:
            utteranceSilenceSeconds
        case .keyword:
            Self.keywordRecognizerSilenceSeconds
        }
    }

    var sendKeyword: VoiceModeSendKeyword? {
        if case let .keyword(keyword) = sendMode {
            return keyword
        }
        return nil
    }
}

/// The spoken word that ends and sends an utterance in keyword send mode.
/// Compared without case, accents or punctuation, as whole words at the end
/// of the speech: "cerca il file, vai" sends "cerca il file", "vai" alone
/// sends what was dictated before, and "vai a casa" is ordinary text.
struct VoiceModeSendKeyword: Sendable, Equatable {
    /// As typed in setup, trimmed.
    let text: String
    /// The folded words compared with the end of the speech.
    let words: [String]

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = VoiceEchoGuard.words(in: trimmed)
        guard !words.isEmpty else {
            return nil
        }
        self.text = trimmed
        self.words = words
    }

    /// The speech before the trailing keyword, without the keyword and a
    /// separating comma: empty when the keyword was said alone, nil when the
    /// speech does not end with the keyword.
    func textBeforeKeyword(in speech: String) -> String? {
        let wordRanges = Self.wordRanges(in: speech)
        guard wordRanges.count >= words.count else {
            return nil
        }
        let tail = wordRanges.suffix(words.count)
        let spoken = tail.map { VoiceEchoGuard.words(in: String(speech[$0])).joined() }
        guard spoken == words else {
            return nil
        }
        let prefix = speech[..<tail.first!.lowerBound]
        return String(prefix).trimmingCharacters(in: Self.separators)
    }

    /// What to send once `speech` ends with the keyword: the text dictated
    /// before it joined to `pending` from earlier segments. Nil when `speech`
    /// does not end with the keyword.
    func utteranceToSend(pending: String, speech: String) -> String? {
        textBeforeKeyword(in: speech).map { Self.joined(pending, $0) }
    }

    /// `pending` and `text` as one utterance.
    static func joined(_ pending: String, _ text: String) -> String {
        [pending, text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",;:-\u{2013}\u{2014}"))

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil {
                    start = index
                }
            } else if let wordStart = start {
                ranges.append(wordStart..<index)
                start = nil
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            ranges.append(wordStart..<text.endIndex)
        }
        return ranges
    }
}

/// What a controller factory of ``VoiceModeSession`` returns.
public enum VoiceModeControllerCreation: Sendable {
    /// The controller to run; the session starts it.
    case ready(any VoiceModeController)
    /// Voice mode cannot run here; the message, which ends with a newline,
    /// explains why.
    case unavailable(String)
}

enum VoiceModePlatform {
    static let unsupportedMessage = "ZenCODE: voice mode requires macOS or Linux.\n"

    /// Builds the controller for this platform. On Linux it requires the
    /// files downloaded from `/setup` > Voice mode. `readingVoiceIdentifier`
    /// is the macOS reading voice chosen there; Linux reads with its installed
    /// Piper voice and ignores it. `options` are the voice mode options chosen
    /// there on either platform.
    static func makeController(
        languageCode: String,
        readingVoiceIdentifier: String? = nil,
        options: VoiceModeOptions = VoiceModeOptions(),
        callbacks: VoiceModeCallbacks
    ) -> VoiceModeControllerCreation {
        #if os(macOS)
        guard DictationVoiceModeController.isSupported else {
            return .unavailable(unsupportedMessage)
        }
        return .ready(DictationVoiceModeController(
            languageCode: languageCode,
            locale: AgentVoiceTranscriptionService.locale(for: languageCode),
            readingVoiceIdentifier: readingVoiceIdentifier,
            options: options,
            callbacks: callbacks
        ))
        #elseif os(Linux)
        switch SherpaOnnxVoiceInstallation.standard().runtimePaths() {
        case let .success(paths):
            return .ready(SherpaVoiceModeController(paths: paths, options: options, callbacks: callbacks))
        case let .failure(error):
            return .unavailable("ZenCODE: \(error.localizedDescription)\n")
        }
        #else
        return .unavailable(unsupportedMessage)
        #endif
    }
}
