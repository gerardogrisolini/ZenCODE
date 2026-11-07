//
//  DictationVoiceModeTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Dictation voice mode")
struct DictationVoiceModeTests {
    @Test
    func anUtteranceEndsAfterTheSilenceGap() {
        let start = ContinuousClock.now
        var segmenter = VoiceDictationSegmenter()
        #expect(segmenter.silence == .milliseconds(5_000))
        #expect(!segmenter.isUtteranceComplete(at: start))

        segmenter.observe("Che cosa", at: start)
        segmenter.observe("Che cosa ho oggi", at: start + .milliseconds(600))
        #expect(!segmenter.isUtteranceComplete(at: start + .milliseconds(5_500)))
        // Repeating the same text does not restart the silence gap.
        segmenter.observe(" Che cosa ho oggi ", at: start + .milliseconds(1_000))
        #expect(segmenter.isUtteranceComplete(at: start + .milliseconds(5_600)))

        #expect(segmenter.takeUtterance() == "Che cosa ho oggi")
        #expect(segmenter.takeUtterance() == nil)
        #expect(!segmenter.hasPendingText)
    }

    @Test
    func theSendKeywordIsRecognisedOnlyAtTheEndAsWholeWords() throws {
        let keyword = try #require(VoiceModeSendKeyword(" Vai! "))
        #expect(keyword.text == "Vai!")
        #expect(keyword.words == ["vai"])
        #expect(keyword.textBeforeKeyword(in: "Cerca il file, vai") == "Cerca il file")
        #expect(keyword.textBeforeKeyword(in: "Cerca il file. VAI.") == "Cerca il file.")
        #expect(keyword.textBeforeKeyword(in: "vai") == "")
        #expect(keyword.textBeforeKeyword(in: "Vai a casa") == nil)
        #expect(keyword.textBeforeKeyword(in: "parla del vaiolo") == nil)
        #expect(keyword.textBeforeKeyword(in: "parla del vaiolo vai") == "parla del vaiolo")
        #expect(keyword.textBeforeKeyword(in: "") == nil)
        // Accents and case do not matter; a phrase is matched word by word.
        let accented = try #require(VoiceModeSendKeyword("così"))
        #expect(accented.textBeforeKeyword(in: "fatto COSI") == "fatto")
        let phrase = try #require(VoiceModeSendKeyword("va bene"))
        #expect(phrase.textBeforeKeyword(in: "procedi, va bene") == "procedi")
        #expect(phrase.textBeforeKeyword(in: "procedi bene") == nil)
        #expect(VoiceModeSendKeyword("...") == nil)
        #expect(VoiceModeSendKeyword("") == nil)
        #expect(keyword.utteranceToSend(pending: "prima parte", speech: "seconda parte vai") == "prima parte seconda parte")
        #expect(keyword.utteranceToSend(pending: "prima parte", speech: "seconda parte") == nil)
        #expect(VoiceModeSendKeyword.joined("  ", "solo") == "solo")
    }

    @Test
    func theKeywordCollectorSendsOnlyOnTheKeywordOrABareAnswerWhenAwaited() throws {
        var collector = VoiceKeywordCollector(keyword: try #require(VoiceModeSendKeyword("vai")))
        #expect(collector.receive("   ", awaitingShortAnswer: false) == .nothing)
        // The keyword alone with nothing collected sends the typed draft.
        #expect(collector.peek("vai", awaitingShortAnswer: false).sends)
        #expect(collector.receive("vai", awaitingShortAnswer: false) == .send(""))
        #expect(collector.receive("Apri il progetto", awaitingShortAnswer: false) == .collected)
        #expect(collector.hasPendingText)
        #expect(collector.pending == "Apri il progetto")
        #expect(!collector.peek("e poi", awaitingShortAnswer: false).sends)
        #expect(collector.peek("e compila, vai", awaitingShortAnswer: false) == .send("Apri il progetto e compila"))
        // Peeking changed nothing.
        #expect(collector.hasPendingText)
        #expect(collector.receive("e compila, vai", awaitingShortAnswer: false) == .send("Apri il progetto e compila"))
        #expect(!collector.hasPendingText)

        // A bare yes or no is sent alone at once only while one is awaited
        // and nothing is collected; otherwise it is ordinary text.
        #expect(collector.peek("sì", awaitingShortAnswer: true).sends)
        #expect(collector.receive("sì", awaitingShortAnswer: true) == .answer("sì"))
        #expect(collector.receive("No", awaitingShortAnswer: true) == .answer("No"))
        #expect(collector.receive("sì", awaitingShortAnswer: false) == .collected)
        #expect(collector.receive("no", awaitingShortAnswer: true) == .collected)
        #expect(collector.receive("vai", awaitingShortAnswer: true) == .send("sì no"))
        collector.reset()
        #expect(!collector.hasPendingText)
        #expect(collector.receive("sì, ma prima vai", awaitingShortAnswer: true) == .send("sì, ma prima"))
    }

    @Test
    func textAfterAResetPartialKeepsTheEarlierSegments() {
        let start = ContinuousClock.now
        var segmenter = VoiceDictationSegmenter()
        segmenter.observe("Cerca il file nella cartella", at: start)
        segmenter.observe("Cerca il file nella cartella", at: start + .milliseconds(1_500), endsSegment: true)
        // The recognizer restarts: the next results hold only the new phrase,
        // which is shorter than what was said before.
        segmenter.observe("Docs", at: start + .milliseconds(3_000))
        #expect(segmenter.hasPendingText)
        #expect(segmenter.text == "Cerca il file nella cartella\nDocs")
        // Blank segments are skipped and every segment is trimmed.
        segmenter.observe("   ", at: start + .milliseconds(3_500), endsSegment: true)
        #expect(segmenter.text == "Cerca il file nella cartella\nDocs")
        segmenter.observe("\n Poi apri il file \n", at: start + .milliseconds(4_000))
        #expect(segmenter.text == "Cerca il file nella cartella\nDocs\nPoi apri il file")
    }

    /// The request's final result repeats the last segment, even when an
    /// earlier result already closed it.
    @Test
    func aFinalResultRepeatingTheLastClosedSegmentIsNotAppended() {
        let start = ContinuousClock.now
        var segmenter = VoiceDictationSegmenter(silence: .seconds(5))
        segmenter.observe("Seconda frase dopo la pausa", at: start)
        segmenter.observe("Seconda frase dopo la pausa", at: start + .seconds(2), endsSegment: true)
        // The final result may differ in case and punctuation only.
        segmenter.observe("seconda frase dopo la pausa.", at: start + .seconds(4), endsSegment: true)
        #expect(segmenter.text == "Seconda frase dopo la pausa")
        #expect(segmenter.isUtteranceComplete(at: start + .seconds(7)))
        #expect(segmenter.takeUtterance() == "Seconda frase dopo la pausa")
    }

    @Test
    func speechStateTracksAnUtteranceUntilItsLastBufferPlays() {
        let start = ContinuousClock.now
        let state = VoiceSpeechState()
        #expect(!state.isSpeaking(at: start))
        #expect(state.echoReference(at: start) == nil)

        let generation = state.begin(text: "Ciao", at: start)
        #expect(state.isSpeaking(at: start))
        #expect(state.bufferScheduled(generation: generation, at: start))
        #expect(state.bufferScheduled(generation: generation, at: start))
        state.synthesisFinished(generation: generation, at: start)
        state.bufferPlayed(generation: generation, at: start + .milliseconds(100))
        #expect(state.isSpeaking(at: start + .milliseconds(100)))
        state.bufferPlayed(generation: generation, at: start + .milliseconds(200))
        #expect(!state.isSpeaking(at: start + .milliseconds(200)))

        // The text remains an echo reference for the echo tail only.
        #expect(state.echoReference(at: start + .milliseconds(1_000)) == "Ciao")
        #expect(state.echoReference(at: start + .milliseconds(1_800)) == nil)
    }

    @Test
    func cancelledSpeechIgnoresLateCallbacks() {
        let start = ContinuousClock.now
        let state = VoiceSpeechState()
        let first = state.begin(text: "Prima risposta", at: start)
        #expect(state.bufferScheduled(generation: first, at: start))
        state.cancel(at: start + .milliseconds(50))
        #expect(!state.isSpeaking(at: start + .milliseconds(50)))
        #expect(!state.bufferScheduled(generation: first, at: start + .milliseconds(60)))
        state.bufferPlayed(generation: first, at: start + .milliseconds(70))
        #expect(state.echoReference(at: start + .milliseconds(100)) == "Prima risposta")

        let second = state.begin(text: "Seconda", at: start + .milliseconds(200))
        #expect(second != first)
        #expect(state.isSpeaking(at: start + .milliseconds(200)))
    }

    /// A slow synthesizer start is not the end of speech: before the first
    /// buffer the utterance stays "speaking" much longer than between buffers.
    @Test
    func aSlowSynthesizerStartIsNotMistakenForTheEndOfSpeech() {
        let start = ContinuousClock.now
        let state = VoiceSpeechState()
        let generation = state.begin(text: "Testo", at: start)
        #expect(state.isSpeaking(at: start + .seconds(5)))
        #expect(!state.isSpeaking(at: start + .seconds(11)))
        #expect(state.bufferScheduled(generation: generation, at: start + .seconds(5)))
        state.bufferPlayed(generation: generation, at: start + .seconds(6))
        #expect(state.isSpeaking(at: start + .seconds(7)))
        #expect(!state.isSpeaking(at: start + .seconds(8) + .milliseconds(100)))
    }

    /// After the assistant stopped speaking, a bare yes or no is the
    /// operator's answer even when the message just read contained it.
    @Test
    func shortAnswersAfterSpeechAreNotTreatedAsEcho() {
        let reading = "Sì, ho finito, ok. Non ci sono errori. Vuoi rispondere?"
        #expect(VoiceEchoGuard.isLikelyEcho("sì", of: reading))
        #expect(VoiceEchoGuard.shouldDrop("sì", spokenReference: reading, isSpeaking: true))
        #expect(!VoiceEchoGuard.shouldDrop("sì", spokenReference: reading, isSpeaking: false))
        #expect(!VoiceEchoGuard.shouldDrop("No.", spokenReference: reading, isSpeaking: false))
        #expect(!VoiceEchoGuard.shouldDrop("ok", spokenReference: reading, isSpeaking: false))
        // The echo of the sentence itself is still dropped after speech.
        #expect(VoiceEchoGuard.shouldDrop("non ci sono errori vuoi rispondere", spokenReference: reading, isSpeaking: false))
        // Something new is never dropped.
        #expect(!VoiceEchoGuard.shouldDrop("aspetta un momento", spokenReference: reading, isSpeaking: true))
    }

    @Test
    func markdownAnswersBecomePlainSpokenText() {
        let markdown = """
        ## Agenda di oggi

        - **10:00** riunione con [Anna](https://example.com/anna)
        - 15:00 chiamata `standup`
        1. Primo punto

        | Ora | Evento |
        |-----|--------|
        | 18:00 | Palestra |

        ---
        ```swift
        let secret = 42
        ```
        Dettagli su https://calendar.example.com/event/123?id=9
        """
        let spoken = VoiceSpeechText.speakable(fromMarkdown: markdown, languageCode: "it")
        #expect(spoken == "Agenda di oggi. 10:00 riunione con Anna. 15:00 chiamata standup. Primo punto. Ora, Evento. 18:00, Palestra. Blocco di codice omesso. Dettagli su calendar.example.com.")
        #expect(!spoken.contains("secret"))
        #expect(!spoken.contains("*"))
        #expect(!spoken.contains("`"))
    }

    @Test
    func voiceLanguageFollowsTheResponseLanguageThenTheSystem() {
        #expect(VoiceLanguage.resolvedCode(responseLanguage: "FR", systemLanguage: "de") == "fr")
        #expect(VoiceLanguage.resolvedCode(responseLanguage: " ", systemLanguage: "de") == "de")
        #expect(VoiceLanguage.resolvedCode(responseLanguage: nil, systemLanguage: nil) == "en")
        // A `language` key saved by earlier versions no longer wins.
        let legacy = try? JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: Data(#"{"version":14,"models":[],"responseLanguage":"en","voice":{"enabled":true,"language":"it"}}"#.utf8)
        )
        #expect(VoiceLanguage.resolvedCode(manifest: legacy) == "en")
        let italian = AgentVoiceTranscriptionService.locale(for: "it")
        #expect(italian.language.languageCode?.identifier == "it")
        #expect(italian.region?.identifier == "IT")
    }

    @Test
    func dictatedUtterancesAreHandledLikeTypedLines() {
        guard case let .input(.submitted(line)) = TerminalChat.dictatedPromptEvent(for: "Che tempo fa domani?") else {
            Issue.record("A dictated utterance must be submitted as a typed line.")
            return
        }
        #expect(line == "Che tempo fa domani?")

        guard case let .voicePromptCompleted(result) = TerminalChat.dictatedPromptEvent(for: "/exit") else {
            Issue.record("A dictated slash-like utterance must never run as a command.")
            return
        }
        guard case let .success(prompt) = result.outcome else {
            Issue.record("Expected a successful voice prompt.")
            return
        }
        #expect(prompt == "/exit")
        #expect(result.origin == .local)
    }

    /// The dictation controller cannot listen without the system permissions,
    /// so reading before it listens must report that nothing was started and
    /// the loop must still be able to read its language and speaking state.
    @Test
    func aControllerThatIsNotListeningReadsNothingAndSaysSo() async {
        let controller = DictationVoiceModeController(
            languageCode: "it",
            locale: Locale(identifier: "it_IT"),
            callbacks: VoiceModeCallbacks(
                systemMessage: { _ in },
                failureMessage: { _ in },
                utteranceRecognized: { _ in },
                dictationChanged: { _, _ in },
                speakingChanged: { _ in }
            )
        )
        #expect(controller.languageCode == "it")
        #expect(await controller.isSpeaking == false)
        #expect(await controller.speak("Nuovo messaggio.", rendering: .plainText) == false)
        #expect(await controller.speak("**Ciao**") == false)
        #expect(await controller.isActive)
        await controller.setPaused(true)
        #expect(await controller.speak("Nuovo messaggio.", rendering: .plainText) == false)
        await controller.stop()
        #expect(await controller.isActive == false)
    }
}
