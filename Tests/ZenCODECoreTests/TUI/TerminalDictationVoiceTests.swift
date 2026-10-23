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
        #expect(segmenter.silence == .milliseconds(2_500))
        #expect(!segmenter.isUtteranceComplete(at: start))

        segmenter.observe("Che cosa", at: start)
        segmenter.observe("Che cosa ho oggi", at: start + .milliseconds(600))
        #expect(!segmenter.isUtteranceComplete(at: start + .milliseconds(3_000)))
        // Repeating the same text does not restart the silence gap.
        segmenter.observe(" Che cosa ho oggi ", at: start + .milliseconds(1_000))
        #expect(segmenter.isUtteranceComplete(at: start + .milliseconds(3_100)))

        #expect(segmenter.takeUtterance() == "Che cosa ho oggi")
        #expect(segmenter.takeUtterance() == nil)
        #expect(!segmenter.hasPendingText)
    }

    @Test
    func emptyRecognitionNeverCompletesAnUtterance() {
        let start = ContinuousClock.now
        var segmenter = TerminalDictationSegmenter()
        segmenter.observe("   ", at: start)
        #expect(!segmenter.isUtteranceComplete(at: start + .seconds(5)))
        #expect(segmenter.takeUtterance() == nil)
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
        let spoken = TerminalVoiceSpeechText.spokenAnswer(fromMarkdown: markdown, languageCode: "it")
        #expect(spoken == TerminalVoiceSpeechText.speakable(fromMarkdown: markdown, languageCode: "it"))
        #expect(spoken == "Fatto. Ho aggiornato il file. Vuoi che faccia il commit?")
    }

    @Test
    func longAnswersReadOnlyTheirFinalSentences() {
        let markdown = """
        ## Riepilogo

        Ho modificato tre file. Ho aggiunto i test.
        - Primo punto completato
        Vuoi che faccia il commit? Oppure preferisci rivedere?
        """
        let spoken = TerminalVoiceSpeechText.spokenAnswer(
            fromMarkdown: markdown,
            languageCode: "it",
            maximumCharacters: 60
        )
        #expect(spoken == "Risposta lunga, leggo solo la parte finale. Vuoi che faccia il commit? Oppure preferisci rivedere?")
    }

    @Test
    func anOverlongFinalSentenceKeepsItsEndFromAWordBoundary() {
        let spoken = TerminalVoiceSpeechText.spokenAnswer(
            fromMarkdown: "Uno due tre quattro cinque sei sette otto nove dieci",
            languageCode: "en",
            maximumCharacters: 20
        )
        #expect(spoken == "Long answer, reading only the end. otto nove dieci.")
    }

    @Test
    func theDefaultLimitBoundsTheSpokenTail() {
        let filler = Array(repeating: "Questa riga riempie la risposta.", count: 100).joined(separator: "\n")
        let markdown = filler + "\nCome vuoi procedere?"
        let spoken = TerminalVoiceSpeechText.spokenAnswer(fromMarkdown: markdown, languageCode: "it")
        let notice = TerminalVoiceSpeechText.longAnswerNotice(languageCode: "it")
        #expect(spoken.hasPrefix(notice + " "))
        #expect(spoken.hasSuffix("Questa riga riempie la risposta. Come vuoi procedere?"))
        #expect(spoken.count - notice.count - 1 <= TerminalVoiceSpeechText.maximumSpokenCharacters)
    }

    @Test
    func longAnswerNoticeFollowsTheLanguage() {
        #expect(TerminalVoiceSpeechText.longAnswerNotice(languageCode: "it-IT") == "Risposta lunga, leggo solo la parte finale.")
        #expect(TerminalVoiceSpeechText.longAnswerNotice(languageCode: "de") == "Lange Antwort, ich lese nur den Schluss.")
        #expect(TerminalVoiceSpeechText.longAnswerNotice(languageCode: "ja") == "Long answer, reading only the end.")
        #expect(TerminalVoiceSpeechText.longAnswerNotice(languageCode: nil) == "Long answer, reading only the end.")
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
