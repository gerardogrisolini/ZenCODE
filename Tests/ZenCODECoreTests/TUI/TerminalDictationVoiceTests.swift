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
}
