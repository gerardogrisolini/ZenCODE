//
//  TerminalVoiceChatPhrasesTests.swift
//  ZenCODECoreTests
//
//  The spoken words of the live chat in voice mode: yes/no in six languages,
//  "message to …" phrases, spoken agent names and the localized texts.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Voice chat phrases")
struct TerminalVoiceChatPhrasesTests {
    private func participant(
        _ name: String,
        id: String? = nil,
        kind: AgentSharedChat.ParticipantKind = .agent,
        isActive: Bool = true
    ) -> AgentSharedChat.Participant {
        AgentSharedChat.Participant(
            id: id ?? "agent-\(name.lowercased())",
            name: name,
            kind: kind,
            isActive: isActive
        )
    }

    // MARK: - Yes / no

    @Test
    func yesIsRecognisedInSixLanguagesWhateverTheCaseAccentsOrPunctuation() {
        for utterance in [
            "Sì.", "SI", "si", "certo", "Va bene!", "d'accordo", "Ok", "okay", "leggi", "Leggilo", "leggila",
            "yes", "Yes, please", "yes please", "yeah", "yep", "Sure.", "please", "go ahead", "Read it",
            "sí", "claro", "Vale", "léelo", "leelo",
            "oui", "Ouais", "d'accord", "lis-le",
            "ja", "Jawohl", "klar", "lies vor",
            "sim", "Pode ler"
        ] {
            #expect(TerminalVoiceChatPhrases.affirmation(in: utterance) == true, "\(utterance)")
        }
    }

    @Test
    func noIsRecognisedInSixLanguages() {
        for utterance in [
            "No.", "NO", "non ora", "Dopo",
            "nope", "Not now", "later",
            "ahora no", "luego",
            "non", "Pas maintenant", "plus tard",
            "nein", "Nicht jetzt", "später", "spater",
            "não", "nao", "Agora não", "depois"
        ] {
            #expect(TerminalVoiceChatPhrases.affirmation(in: utterance) == false, "\(utterance)")
        }
    }

    @Test
    func anythingElseIsNotAnAnswer() {
        for utterance in [
            "", "  ", "sì ma prima leggi il file", "yes and then stop", "no grazie, poi",
            "Che ore sono?", "leggi il file", "okay okay"
        ] {
            #expect(TerminalVoiceChatPhrases.affirmation(in: utterance) == nil, "\(utterance)")
        }
    }

    // MARK: - "Message to …"

    @Test
    func sendPhrasesTargetTheCoordinatorInSixLanguages() throws {
        for utterance in [
            "messaggio al coordinatore: fermati",
            "Invia un messaggio al coordinatore, fermati",
            "manda messaggio al coordinatore - fermati",
            "message to the coordinator: fermati",
            "Send a message to coordinator. fermati",
            "mensaje al coordinador: fermati",
            "envía un mensaje al coordinador fermati",
            "message au coordinateur : fermati",
            "envoie un message au coordinateur, fermati",
            "Nachricht an den Koordinator: fermati",
            "sende eine nachricht an koordinator fermati",
            "mensagem ao coordenador: fermati",
            "envia uma mensagem para o coordenador, fermati"
        ] {
            let request = try #require(TerminalVoiceChatPhrases.sendRequest(in: utterance), "\(utterance)")
            #expect(request.target == .coordinator, "\(utterance)")
            #expect(request.text == "fermati", "\(utterance)")
        }
    }

    @Test
    func sendPhrasesTargetEveryoneInSixLanguages() throws {
        for utterance in [
            "messaggio a tutti: pausa",
            "message to all: pausa",
            "message to everyone, pausa",
            "message to everybody pausa",
            "mensaje a todos: pausa",
            "message à tous : pausa",
            "Nachricht an alle: pausa",
            "mensagem a todos: pausa",
            "mensagem para todos, pausa"
        ] {
            let request = try #require(TerminalVoiceChatPhrases.sendRequest(in: utterance), "\(utterance)")
            #expect(request.target == .all, "\(utterance)")
            #expect(request.text == "pausa", "\(utterance)")
        }
    }

    @Test
    func sendPhrasesWithoutTextAskForIt() throws {
        for utterance in [
            "messaggio al coordinatore", "messaggio al coordinatore.", "messaggio a tutti:",
            "message to the coordinator", "message to all", "Nachricht an alle", "mensagem ao coordenador"
        ] {
            let request = try #require(TerminalVoiceChatPhrases.sendRequest(in: utterance), "\(utterance)")
            #expect(request.text == nil, "\(utterance)")
        }
    }

    @Test
    func sendPhrasesKeepTheSpokenTextAsItWas() throws {
        let request = try #require(TerminalVoiceChatPhrases.sendRequest(
            in: "MESSAGGIO al Coordinatore: Perché è così? Fermati."
        ))
        #expect(request.target == .coordinator)
        #expect(request.text == "Perché è così? Fermati.")

        // Folding may change the number of scalars inside the matched prefix
        // (İ → i, ß → ss); the text still starts where it was spoken.
        let turkish = try #require(TerminalVoiceChatPhrases.sendRequest(in: "İnvia un messaggio al coordinatore: x"))
        #expect(turkish.target == .coordinator)
        #expect(turkish.text == "x")
        let german = try #require(TerminalVoiceChatPhrases.sendRequest(in: "Nachricht an alle: Straße"))
        #expect(german.target == .all)
        #expect(german.text == "Straße")
        let strasse = participant("Straße")
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: "Straße: Grüße", participants: [strasse])
                == .agent(strasse, text: "Grüße")
        )
    }

    @Test
    func sendPhrasesToANameKeepTheWholeRemainder() throws {
        for (utterance, remainder) in [
            ("messaggio a Reviewer: controlla il diff", "Reviewer: controlla il diff"),
            ("message to Reviewer, check the diff", "Reviewer, check the diff"),
            ("mensaje a Reviewer", "Reviewer"),
            ("message à Reviewer: regarde", "Reviewer: regarde"),
            ("Nachricht an Reviewer: prüfe", "Reviewer: prüfe"),
            ("mensagem para Reviewer: verifica", "Reviewer: verifica"),
            ("mensagem a Reviewer", "Reviewer")
        ] {
            let request = try #require(TerminalVoiceChatPhrases.sendRequest(in: utterance), "\(utterance)")
            #expect(request.target == .named(remainder: remainder), "\(utterance)")
            #expect(request.text == nil, "\(utterance)")
        }
    }

    @Test
    func reservedWordsWinOverAnAgentWithTheSameName() throws {
        let request = try #require(TerminalVoiceChatPhrases.sendRequest(in: "messaggio a tutti: ciao"))
        #expect(request.target == .all)
        // Only reachable when the grammar did not claim the word first.
        let everyone = participant("tutti")
        let recipient = TerminalVoiceChatPhrases.resolveNamedRecipient(
            remainder: "tutti: ciao",
            participants: [everyone]
        )
        #expect(recipient == .agent(everyone, text: "ciao"))
    }

    @Test
    func ordinaryUtterancesAreNotSendPhrases() {
        for utterance in [
            "", "messaggio", "messaggio a", "message", "message to", "il messaggio al coordinatore era chiaro",
            "manda il file", "Che tempo fa?", "messaggio per Anna: ciao"
        ] {
            #expect(TerminalVoiceChatPhrases.sendRequest(in: utterance) == nil, "\(utterance)")
        }
    }

    // MARK: - Spoken names

    @Test
    func theLongestActiveAgentNameWins() {
        let review = participant("Review")
        let reviewer = participant("Reviewer")
        let recipient = TerminalVoiceChatPhrases.resolveNamedRecipient(
            remainder: "Reviewer: controlla il diff",
            participants: [review, reviewer]
        )
        #expect(recipient == .agent(reviewer, text: "controlla il diff"))

        let shorter = TerminalVoiceChatPhrases.resolveNamedRecipient(
            remainder: "review, controlla",
            participants: [reviewer, review]
        )
        #expect(shorter == .agent(review, text: "controlla"))
    }

    @Test
    func namesMatchWithoutCaseOrAccentsOnWordBoundaries() {
        let coder = participant("Códe Writer")
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: "code writer scrivi", participants: [coder])
                == .agent(coder, text: "scrivi")
        )
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: "Code Writer", participants: [coder])
                == .agent(coder, text: nil)
        )
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: "Code Writers: ciao", participants: [coder])
                == .unknown(spokenName: "Code Writers")
        )
    }

    /// Agent names such as `parser-reviewer` are heard with the hyphen, a
    /// space or nothing special between the words.
    @Test
    func hyphenatedNamesMatchWithAnyPunctuationBetweenTheirWords() {
        let reviewer = participant("parser-reviewer")
        for remainder in ["parser-reviewer: controlla", "parser reviewer, controlla", "Parser Reviewer controlla"] {
            #expect(
                TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: remainder, participants: [reviewer])
                    == .agent(reviewer, text: "controlla"),
                "\(remainder)"
            )
        }
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: "parser-reviewers: ciao", participants: [reviewer])
                == .unknown(spokenName: "parser-reviewers")
        )
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: "build v1.2 - ciao", participants: [])
                == .unknown(spokenName: "build v1.2")
        )
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: "Anna. ciao", participants: [])
                == .unknown(spokenName: "Anna")
        )
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: ": ciao", participants: [])
                == .unknown(spokenName: "")
        )
    }

    @Test
    func inactiveAgentsCoordinatorsAndUnknownNamesAreReported() {
        let gone = participant("Builder", isActive: false)
        let coordinator = participant("Anna", id: "coordinator:room", kind: .coordinator)
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(
                remainder: "Builder: ciao",
                participants: [gone, coordinator]
            ) == .unknown(spokenName: "Builder")
        )
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: "Anna, ciao", participants: [coordinator])
                == .unknown(spokenName: "Anna")
        )
        let long = String(repeating: "a", count: 80)
        #expect(
            TerminalVoiceChatPhrases.resolveNamedRecipient(remainder: long, participants: [])
                == .unknown(spokenName: String(repeating: "a", count: TerminalVoiceChatPhrases.maximumSpokenNameLength))
        )
    }

    // MARK: - Spoken texts

    @Test
    func announcementsFollowTheLanguageAndFallBackToEnglish() {
        #expect(
            TerminalVoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 0, languageCode: "it")
                == "Nuovo messaggio da Reviewer. Vuoi che lo legga?"
        )
        #expect(
            TerminalVoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: true, remaining: 2, languageCode: "it-IT")
                == "Nuovo messaggio da Reviewer a tutti, altri 2 in attesa. Vuoi che lo legga?"
        )
        #expect(
            TerminalVoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 1, languageCode: "it")
                == "Nuovo messaggio da Reviewer, un altro in attesa. Vuoi che lo legga?"
        )
        #expect(
            TerminalVoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 1, languageCode: "de")
                == "Neue Nachricht von Reviewer, 1 weitere wartet. Soll ich sie vorlesen?"
        )
        #expect(
            TerminalVoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 3, languageCode: "fr")
                == "Nouveau message de Reviewer, 3 autres en attente. Voulez-vous que je le lise ?"
        )
        #expect(
            TerminalVoiceChatPhrases.announcement(sender: "coordinator", isBroadcast: false, remaining: 1, languageCode: "en")
                == "New message from coordinator, 1 more waiting. Do you want me to read it?"
        )
        #expect(
            TerminalVoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: true, remaining: 0, languageCode: "ja")
                == "New message from Reviewer to all. Do you want me to read it?"
        )
        #expect(
            TerminalVoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 0, languageCode: nil)
                == "New message from Reviewer. Do you want me to read it?"
        )
    }

    @Test
    func readingEndsWithTheReplyQuestion() {
        #expect(
            TerminalVoiceChatPhrases.readAloud(text: "Ho finito", languageCode: "it")
                == "Ho finito. Vuoi rispondere?"
        )
        #expect(
            TerminalVoiceChatPhrases.readAloud(text: "Posso procedere?", languageCode: "it")
                == "Posso procedere? Vuoi rispondere?"
        )
        #expect(
            TerminalVoiceChatPhrases.readAloud(text: "Done!", languageCode: "en")
                == "Done! Do you want to reply?"
        )
        #expect(TerminalVoiceChatPhrases.readAloud(text: "  ", languageCode: "en") == "Do you want to reply?")
    }

    @Test
    func shortTextsFollowTheLanguageAndFallBackToEnglish() {
        #expect(TerminalVoiceChatPhrases.replyPrompt(languageCode: "it") == "Dimmi la risposta.")
        #expect(TerminalVoiceChatPhrases.replyPrompt(languageCode: "xx") == "Tell me your reply.")
        #expect(TerminalVoiceChatPhrases.messagePrompt(languageCode: "it") == "Dimmi il messaggio.")
        #expect(TerminalVoiceChatPhrases.messagePrompt(languageCode: nil) == "Tell me the message.")
        #expect(TerminalVoiceChatPhrases.sent(languageCode: "it") == "Inviato.")
        #expect(TerminalVoiceChatPhrases.sent(languageCode: "de") == "Gesendet.")
        #expect(TerminalVoiceChatPhrases.sent(languageCode: "ja") == "Sent.")
        #expect(TerminalVoiceChatPhrases.sendFailed(languageCode: "it") == "Invio non riuscito.")
        #expect(TerminalVoiceChatPhrases.sendFailed(languageCode: "en") == "Sending failed.")
        #expect(TerminalVoiceChatPhrases.agentInactive(name: "Builder", languageCode: "it") == "Builder non è più attivo.")
        #expect(TerminalVoiceChatPhrases.agentInactive(name: "Builder", languageCode: "fr") == "Builder n'est plus actif.")
        #expect(TerminalVoiceChatPhrases.agentInactive(name: "Builder", languageCode: nil) == "Builder is no longer active.")
        #expect(TerminalVoiceChatPhrases.unknownAgent(name: "Anna", languageCode: "it") == "Nessun agente attivo si chiama Anna.")
        #expect(TerminalVoiceChatPhrases.unknownAgent(name: "Anna", languageCode: "es") == "Ningún agente activo se llama Anna.")
        #expect(TerminalVoiceChatPhrases.unknownAgent(name: "Anna", languageCode: "pt-BR") == "Nenhum agente ativo se chama Anna.")
        #expect(TerminalVoiceChatPhrases.unknownAgent(name: "Anna", languageCode: "ko") == "No active agent is named Anna.")
    }
}
