//
//  TerminalDictationVoiceTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Terminal dictation voice")
struct TerminalDictationVoiceTests {
    @Test
    func voiceSubcommandsParseCaseInsensitively() {
        #expect(TerminalVoiceCommandAction(argument: "") == .togglePause)
        #expect(TerminalVoiceCommandAction(argument: "  ") == .togglePause)
        #expect(TerminalVoiceCommandAction(argument: "on") == .turnOn)
        #expect(TerminalVoiceCommandAction(argument: " ON ") == .turnOn)
        #expect(TerminalVoiceCommandAction(argument: "off") == .turnOff)
        #expect(TerminalVoiceCommandAction(argument: "Pause") == .pause)
        #expect(TerminalVoiceCommandAction(argument: "resume") == .resume)
        #expect(TerminalVoiceCommandAction(argument: "start") == .usage)
        #expect(TerminalVoiceCommandAction(argument: "on now") == .usage)
        #expect(TerminalVoiceCommandAction.usageMessage == "Usage: /voice [on|off|pause|resume]\n")
    }

    @Test
    func anUtteranceEndsAfterTheSilenceGap() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
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
        let keyword = try #require(TerminalVoiceSendKeyword(" Vai! "))
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
        let accented = try #require(TerminalVoiceSendKeyword("così"))
        #expect(accented.textBeforeKeyword(in: "fatto COSI") == "fatto")
        let phrase = try #require(TerminalVoiceSendKeyword("va bene"))
        #expect(phrase.textBeforeKeyword(in: "procedi, va bene") == "procedi")
        #expect(phrase.textBeforeKeyword(in: "procedi bene") == nil)
        #expect(TerminalVoiceSendKeyword("...") == nil)
        #expect(TerminalVoiceSendKeyword("") == nil)
        #expect(keyword.utteranceToSend(pending: "prima parte", speech: "seconda parte vai") == "prima parte seconda parte")
        #expect(keyword.utteranceToSend(pending: "prima parte", speech: "seconda parte") == nil)
        #expect(TerminalVoiceSendKeyword.joined("  ", "solo") == "solo")
    }

    @Test
    func theSendKeywordEndsMultiLineSpeechAndKeepsItsInnerNewlines() throws {
        let keyword = try #require(TerminalVoiceSendKeyword("vai"))
        #expect(keyword.textBeforeKeyword(in: "Cerca il file\nnella cartella Docs, vai") == "Cerca il file\nnella cartella Docs")
        // The keyword said as a segment of its own.
        #expect(keyword.textBeforeKeyword(in: "Cerca il file\nnella cartella Docs\nvai") == "Cerca il file\nnella cartella Docs")
        #expect(keyword.textBeforeKeyword(in: "Cerca il file\nvai a casa") == nil)
        #expect(keyword.utteranceToSend(pending: "prima parte", speech: "seconda\nparte, vai") == "prima parte seconda\nparte")

        var segmenter = TerminalDictationSegmenter()
        let start = ContinuousClock.now
        segmenter.observe("Cerca il file", at: start, endsSegment: true)
        segmenter.observe("nella cartella Docs, vai", at: start + .seconds(3))
        #expect(keyword.textBeforeKeyword(in: segmenter.text) == "Cerca il file\nnella cartella Docs")
    }

    @Test
    func theKeywordCollectorSendsOnlyOnTheKeywordOrABareAnswerWhenAwaited() throws {
        var collector = TerminalVoiceKeywordCollector(keyword: try #require(TerminalVoiceSendKeyword("vai")))
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
    func aBareYesOrNoIsAnAnswerOnlyWhileTheDialogueAwaitsOne() {
        #expect(TerminalVoiceUtterance.isAwaitedAnswer("Sì.", awaitingShortAnswer: true))
        #expect(TerminalVoiceUtterance.isAwaitedAnswer("no", awaitingShortAnswer: true))
        #expect(!TerminalVoiceUtterance.isAwaitedAnswer("sì", awaitingShortAnswer: false))
        #expect(!TerminalVoiceUtterance.isAwaitedAnswer("sì, ma prima", awaitingShortAnswer: true))
    }

    @Test
    func stableTextIsIndependentOfTheSilenceGap() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter(silence: .seconds(5))
        #expect(!segmenter.hasStableText(for: .zero, at: start))
        segmenter.observe("Cerca il file vai", at: start)
        #expect(!segmenter.hasStableText(for: .milliseconds(600), at: start + .milliseconds(500)))
        #expect(segmenter.hasStableText(for: .milliseconds(600), at: start + .milliseconds(600)))
        #expect(!segmenter.isUtteranceComplete(at: start + .milliseconds(600)))
        #expect(segmenter.text == "Cerca il file vai")
    }

    @Test
    func theTextEndsWithAClosedSegmentOnlyAfterAFinalResult() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
        #expect(!segmenter.endsWithClosedSegment)
        segmenter.observe("Cerca il file vai", at: start)
        #expect(!segmenter.endsWithClosedSegment)
        segmenter.observe("Cerca il file vai", at: start + .seconds(2), endsSegment: true)
        #expect(segmenter.endsWithClosedSegment)
        // An empty result after the final one opens no segment.
        segmenter.observe("", at: start + .seconds(3))
        #expect(segmenter.endsWithClosedSegment)
        segmenter.observe("Poi", at: start + .seconds(4))
        #expect(!segmenter.endsWithClosedSegment)
        segmenter.observe("Poi vai", at: start + .seconds(5), endsSegment: true)
        #expect(segmenter.endsWithClosedSegment)
        segmenter.reset()
        #expect(!segmenter.endsWithClosedSegment)
    }

    @Test
    func emptyRecognitionNeverCompletesAnUtterance() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
        segmenter.observe("   ", at: start)
        #expect(!segmenter.isUtteranceComplete(at: start + .seconds(5)))
        #expect(segmenter.takeUtterance() == nil)
        // Neither does an empty result that closes a segment.
        segmenter.observe("", at: start, endsSegment: true)
        #expect(!segmenter.hasPendingText)
        #expect(!segmenter.isUtteranceComplete(at: start + .seconds(5)))
    }

    @Test
    func speechSegmentsAreJoinedWithANewline() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
        segmenter.observe("Prima frase", at: start)
        segmenter.observe("Prima frase di prova", at: start + .milliseconds(600))
        #expect(segmenter.text == "Prima frase di prova")
        segmenter.observe("Prima frase di prova", at: start + .milliseconds(2_000), endsSegment: true)
        #expect(segmenter.text == "Prima frase di prova")

        segmenter.observe("Seconda", at: start + .milliseconds(4_000))
        #expect(segmenter.text == "Prima frase di prova\nSeconda")
        segmenter.observe(" Seconda frase dopo la pausa ", at: start + .milliseconds(4_600), endsSegment: true)
        segmenter.observe("Terza", at: start + .milliseconds(7_000))
        #expect(segmenter.text == "Prima frase di prova\nSeconda frase dopo la pausa\nTerza")
        #expect(TerminalDictationSegmenter.segmentSeparator == "\n")
    }

    @Test
    func textAfterAResetPartialKeepsTheEarlierSegments() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
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

    @Test
    func anEmptyPartialAfterACommitKeepsTheTextAndTheSilenceGap() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter(silence: .seconds(5))
        segmenter.observe("Prima frase", at: start)
        segmenter.observe("Prima frase", at: start + .seconds(2), endsSegment: true)
        segmenter.observe("", at: start + .seconds(3))
        segmenter.observe("  ", at: start + .seconds(4))
        #expect(segmenter.text == "Prima frase")
        #expect(segmenter.hasPendingText)
        // Neither the commit nor the empty partials moved the gap.
        #expect(!segmenter.isUtteranceComplete(at: start + .milliseconds(4_999)))
        #expect(segmenter.isUtteranceComplete(at: start + .seconds(5)))
    }

    @Test
    func theSilenceGapIsMeasuredFromTheLastChangeOfTheCombinedText() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter(silence: .seconds(5))
        segmenter.observe("Uno", at: start)
        segmenter.observe("Uno", at: start + .seconds(2), endsSegment: true)
        #expect(segmenter.hasStableText(for: .seconds(2), at: start + .seconds(2)))

        // A new segment changes the combined text: the gap restarts.
        segmenter.observe("Due", at: start + .seconds(3))
        #expect(!segmenter.hasStableText(for: .seconds(2), at: start + .milliseconds(4_999)))
        #expect(segmenter.hasStableText(for: .seconds(2), at: start + .seconds(5)))
        #expect(!segmenter.isUtteranceComplete(at: start + .milliseconds(7_999)))
        // Closing that segment with the same words does not move it.
        segmenter.observe("Due", at: start + .seconds(4), endsSegment: true)
        #expect(segmenter.isUtteranceComplete(at: start + .seconds(8)))
        #expect(segmenter.text == "Uno\nDue")

        // Words added to the next segment do.
        segmenter.observe("Tre", at: start + .seconds(7))
        #expect(!segmenter.isUtteranceComplete(at: start + .seconds(8)))
        #expect(segmenter.isUtteranceComplete(at: start + .seconds(12)))
    }

    @Test
    func takingTheUtteranceReturnsEverySegmentAndClears() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
        segmenter.observe("Prima", at: start, endsSegment: true)
        segmenter.observe("Seconda", at: start + .seconds(1), endsSegment: true)
        segmenter.observe("Terza in corso", at: start + .seconds(2))
        #expect(segmenter.takeUtterance() == "Prima\nSeconda\nTerza in corso")
        #expect(segmenter.text.isEmpty)
        #expect(!segmenter.hasPendingText)
        #expect(!segmenter.isUtteranceComplete(at: start + .seconds(20)))
        #expect(segmenter.takeUtterance() == nil)
        // The next utterance starts from nothing.
        segmenter.observe("Nuova", at: start + .seconds(21))
        #expect(segmenter.text == "Nuova")
    }

    @Test
    func resettingForgetsEverySegment() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
        segmenter.observe("Prima", at: start, endsSegment: true)
        segmenter.observe("Seconda", at: start + .seconds(1))
        segmenter.reset()
        #expect(segmenter.text.isEmpty)
        #expect(!segmenter.hasPendingText)
        #expect(!segmenter.isUtteranceComplete(at: start + .seconds(20)))
        #expect(segmenter.takeUtterance() == nil)
        segmenter.observe("Dopo", at: start + .seconds(21))
        #expect(segmenter.text == "Dopo")
    }

    /// The request's final result repeats the last segment, even when an
    /// earlier result already closed it.
    @Test
    func aFinalResultRepeatingTheLastClosedSegmentIsNotAppended() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter(silence: .seconds(5))
        segmenter.observe("Seconda frase dopo la pausa", at: start)
        segmenter.observe("Seconda frase dopo la pausa", at: start + .seconds(2), endsSegment: true)
        // The final result may differ in case and punctuation only.
        segmenter.observe("seconda frase dopo la pausa.", at: start + .seconds(4), endsSegment: true)
        #expect(segmenter.text == "Seconda frase dopo la pausa")
        #expect(segmenter.isUtteranceComplete(at: start + .seconds(7)))
        #expect(segmenter.takeUtterance() == "Seconda frase dopo la pausa")
    }

    @Test
    func theSamePhraseSaidTwiceIsKeptTwice() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
        segmenter.observe("Sì", at: start)
        segmenter.observe("Sì", at: start + .seconds(2), endsSegment: true)
        segmenter.observe("Sì", at: start + .seconds(4))
        segmenter.observe("Sì", at: start + .seconds(6), endsSegment: true)
        #expect(segmenter.text == "Sì\nSì")
    }

    @Test
    func aClosingResultCommitsTheSegmentInProgressOnce() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
        segmenter.observe("Apri il", at: start)
        // The closing result may complete the words of the partial.
        segmenter.observe("Apri il progetto", at: start + .seconds(1), endsSegment: true)
        #expect(segmenter.text == "Apri il progetto")
        segmenter.observe("e compila", at: start + .seconds(3))
        // A closing result without words closes the segment as it is.
        segmenter.observe("", at: start + .seconds(4), endsSegment: true)
        #expect(segmenter.text == "Apri il progetto\ne compila")
        segmenter.observe("ora", at: start + .seconds(5))
        #expect(segmenter.text == "Apri il progetto\ne compila\nora")
    }

    @Test
    func dictationResultsCarryWhetherTheyCloseASegment() {
        let open = TerminalDictationEvent.partial(generation: 1, text: "Prima", endsSegment: false)
        let closing = TerminalDictationEvent.partial(generation: 1, text: "Prima", endsSegment: true)
        #expect(open != closing)
        #expect(closing == .partial(generation: 1, text: "Prima", endsSegment: true))
    }

    @Test
    func echoGuardRecognisesTheAssistantsOwnWords() {
        let spoken = "Oggi hai tre appuntamenti: alle dieci, alle quindici e alle diciotto."
        #expect(TerminalVoiceEchoGuard.isLikelyEcho("oggi hai tre appuntamenti", of: spoken))
        #expect(TerminalVoiceEchoGuard.isLikelyEcho("Alle QUINDICI", of: spoken))
        #expect(!TerminalVoiceEchoGuard.isLikelyEcho("aspetta, spostali a domani", of: spoken))
        #expect(!TerminalVoiceEchoGuard.isLikelyEcho("stop", of: spoken))
        #expect(!TerminalVoiceEchoGuard.isLikelyEcho("", of: spoken))
        #expect(!TerminalVoiceEchoGuard.isLikelyEcho("oggi", of: ""))
        // Diacritics and case are ignored.
        #expect(TerminalVoiceEchoGuard.isLikelyEcho("perche e cosi", of: "Perché è così."))
    }

    @Test
    func speechStateTracksAnUtteranceUntilItsLastBufferPlays() {
        let start = ContinuousClock.now
        let state = TerminalVoiceSpeechState()
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
        let state = TerminalVoiceSpeechState()
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

    @Test
    func synthesisWithoutATerminalBufferEventuallyStopsSpeaking() {
        let start = ContinuousClock.now
        let state = TerminalVoiceSpeechState()
        let generation = state.begin(text: "Testo", at: start)
        #expect(state.bufferScheduled(generation: generation, at: start))
        state.bufferPlayed(generation: generation, at: start + .milliseconds(500))
        #expect(state.isSpeaking(at: start + .milliseconds(600)))
        #expect(!state.isSpeaking(at: start + .milliseconds(2_600)))
    }

    /// A slow synthesizer start is not the end of speech: before the first
    /// buffer the utterance stays "speaking" much longer than between buffers.
    @Test
    func aSlowSynthesizerStartIsNotMistakenForTheEndOfSpeech() {
        let start = ContinuousClock.now
        let state = TerminalVoiceSpeechState()
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
        #expect(TerminalVoiceEchoGuard.isLikelyEcho("sì", of: reading))
        #expect(TerminalVoiceEchoGuard.shouldDrop("sì", spokenReference: reading, isSpeaking: true))
        #expect(!TerminalVoiceEchoGuard.shouldDrop("sì", spokenReference: reading, isSpeaking: false))
        #expect(!TerminalVoiceEchoGuard.shouldDrop("No.", spokenReference: reading, isSpeaking: false))
        #expect(!TerminalVoiceEchoGuard.shouldDrop("ok", spokenReference: reading, isSpeaking: false))
        // The echo of the sentence itself is still dropped after speech.
        #expect(TerminalVoiceEchoGuard.shouldDrop("non ci sono errori vuoi rispondere", spokenReference: reading, isSpeaking: false))
        // Something new is never dropped.
        #expect(!TerminalVoiceEchoGuard.shouldDrop("aspetta un momento", spokenReference: reading, isSpeaking: true))
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
        let spoken = TerminalVoiceSpeechText.speakable(fromMarkdown: markdown, languageCode: "it")
        #expect(spoken == "Agenda di oggi. 10:00 riunione con Anna. 15:00 chiamata standup. Primo punto. Ora, Evento. 18:00, Palestra. Blocco di codice omesso. Dettagli su calendar.example.com.")
        #expect(!spoken.contains("secret"))
        #expect(!spoken.contains("*"))
        #expect(!spoken.contains("`"))
    }

    @Test
    func codeBlockNoticeFollowsTheLanguage() {
        #expect(TerminalVoiceSpeechText.codeBlockNotice(languageCode: "it-IT") == "Blocco di codice omesso.")
        #expect(TerminalVoiceSpeechText.codeBlockNotice(languageCode: "en") == "Code block omitted.")
        #expect(TerminalVoiceSpeechText.codeBlockNotice(languageCode: "ja") == "Code block omitted.")
        #expect(TerminalVoiceSpeechText.codeBlockNotice(languageCode: nil) == "Code block omitted.")
    }

    @Test
    func shortAnswersAreReadWhole() {
        let markdown = "## Fatto\n\nHo aggiornato il file. Vuoi che faccia il commit?"
        let spoken = TerminalVoiceSpeechText.speakable(fromMarkdown: markdown, languageCode: "it")
        #expect(spoken == "Fatto. Ho aggiornato il file. Vuoi che faccia il commit?")
    }

    @Test
    func aLongAnswerIsReadWholeWithoutANotice() {
        let lines = (1...100).map { "Questa è la riga numero \($0) della risposta." }
        let markdown = lines.joined(separator: "\n") + "\nCome vuoi procedere?"
        let spoken = TerminalVoiceSpeechText.speakable(fromMarkdown: markdown, languageCode: "it")
        #expect(spoken == lines.joined(separator: " ") + " Come vuoi procedere?")
        #expect(spoken.count > 3_000)
        #expect(spoken.hasPrefix("Questa è la riga numero 1 della risposta."))
        #expect(!spoken.contains("Risposta lunga"))
        #expect(!spoken.contains("Long answer"))
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
        let controller = TerminalDictationVoiceController(
            languageCode: "it",
            locale: Locale(identifier: "it_IT"),
            callbacks: TerminalVoiceCallbacks(
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
