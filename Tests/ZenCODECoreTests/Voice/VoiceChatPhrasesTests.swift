//
//  VoiceChatPhrasesTests.swift
//  ZenCODECoreTests
//
//  The spoken words of the live chat in voice mode: yes/no in six languages,
//  "message to …" phrases, spoken agent names and the localized texts.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Voice chat phrases")
struct VoiceChatPhrasesTests {
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
            #expect(VoiceChatPhrases.affirmation(in: utterance) == true, "\(utterance)")
        }
    }

    @Test
    func anythingElseIsNotAnAnswer() {
        for utterance in [
            "", "  ", "sì ma prima leggi il file", "yes and then stop", "no grazie, poi",
            "Che ore sono?", "leggi il file", "okay okay"
        ] {
            #expect(VoiceChatPhrases.affirmation(in: utterance) == nil, "\(utterance)")
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
            let request = try #require(VoiceChatPhrases.sendRequest(in: utterance), "\(utterance)")
            #expect(request.target == .coordinator, "\(utterance)")
            #expect(request.text == "fermati", "\(utterance)")
        }
    }

    @Test
    func sendPhrasesKeepTheSpokenTextAsItWas() throws {
        let request = try #require(VoiceChatPhrases.sendRequest(
            in: "MESSAGGIO al Coordinatore: Perché è così? Fermati."
        ))
        #expect(request.target == .coordinator)
        #expect(request.text == "Perché è così? Fermati.")

        // Folding may change the number of scalars inside the matched prefix
        // (İ → i, ß → ss); the text still starts where it was spoken.
        let turkish = try #require(VoiceChatPhrases.sendRequest(in: "İnvia un messaggio al coordinatore: x"))
        #expect(turkish.target == .coordinator)
        #expect(turkish.text == "x")
        let german = try #require(VoiceChatPhrases.sendRequest(in: "Nachricht an alle: Straße"))
        #expect(german.target == .all)
        #expect(german.text == "Straße")
        let strasse = participant("Straße")
        #expect(
            VoiceChatPhrases.resolveNamedRecipient(remainder: "Straße: Grüße", participants: [strasse])
                == .agent(strasse, text: "Grüße")
        )
    }

    @Test
    func ordinaryUtterancesAreNotSendPhrases() {
        for utterance in [
            "", "messaggio", "messaggio a", "message", "message to", "il messaggio al coordinatore era chiaro",
            "manda il file", "Che tempo fa?", "messaggio per Anna: ciao"
        ] {
            #expect(VoiceChatPhrases.sendRequest(in: utterance) == nil, "\(utterance)")
        }
    }

    // MARK: - Spoken names

    @Test
    func theLongestActiveAgentNameWins() {
        let review = participant("Review")
        let reviewer = participant("Reviewer")
        let recipient = VoiceChatPhrases.resolveNamedRecipient(
            remainder: "Reviewer: controlla il diff",
            participants: [review, reviewer]
        )
        #expect(recipient == .agent(reviewer, text: "controlla il diff"))

        let shorter = VoiceChatPhrases.resolveNamedRecipient(
            remainder: "review, controlla",
            participants: [reviewer, review]
        )
        #expect(shorter == .agent(review, text: "controlla"))
    }

    /// Agent names such as `parser-reviewer` are heard with the hyphen, a
    /// space or nothing special between the words.
    @Test
    func hyphenatedNamesMatchWithAnyPunctuationBetweenTheirWords() {
        let reviewer = participant("parser-reviewer")
        for remainder in ["parser-reviewer: controlla", "parser reviewer, controlla", "Parser Reviewer controlla"] {
            #expect(
                VoiceChatPhrases.resolveNamedRecipient(remainder: remainder, participants: [reviewer])
                    == .agent(reviewer, text: "controlla"),
                "\(remainder)"
            )
        }
        #expect(
            VoiceChatPhrases.resolveNamedRecipient(remainder: "parser-reviewers: ciao", participants: [reviewer])
                == .unknown(spokenName: "parser-reviewers")
        )
        #expect(
            VoiceChatPhrases.resolveNamedRecipient(remainder: "build v1.2 - ciao", participants: [])
                == .unknown(spokenName: "build v1.2")
        )
        #expect(
            VoiceChatPhrases.resolveNamedRecipient(remainder: "Anna. ciao", participants: [])
                == .unknown(spokenName: "Anna")
        )
        #expect(
            VoiceChatPhrases.resolveNamedRecipient(remainder: ": ciao", participants: [])
                == .unknown(spokenName: "")
        )
    }

    @Test
    func inactiveAgentsCoordinatorsAndUnknownNamesAreReported() {
        let gone = participant("Builder", isActive: false)
        let coordinator = participant("Anna", id: "coordinator:room", kind: .coordinator)
        #expect(
            VoiceChatPhrases.resolveNamedRecipient(
                remainder: "Builder: ciao",
                participants: [gone, coordinator]
            ) == .unknown(spokenName: "Builder")
        )
        #expect(
            VoiceChatPhrases.resolveNamedRecipient(remainder: "Anna, ciao", participants: [coordinator])
                == .unknown(spokenName: "Anna")
        )
        let long = String(repeating: "a", count: 80)
        #expect(
            VoiceChatPhrases.resolveNamedRecipient(remainder: long, participants: [])
                == .unknown(spokenName: String(repeating: "a", count: VoiceChatPhrases.maximumSpokenNameLength))
        )
    }

    // MARK: - Spoken texts

    @Test
    func announcementsFollowTheLanguageAndFallBackToEnglish() {
        #expect(
            VoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 0, languageCode: "it")
                == "Nuovo messaggio da Reviewer. Vuoi che lo legga?"
        )
        #expect(
            VoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: true, remaining: 2, languageCode: "it-IT")
                == "Nuovo messaggio da Reviewer a tutti, altri 2 in attesa. Vuoi che lo legga?"
        )
        #expect(
            VoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 1, languageCode: "it")
                == "Nuovo messaggio da Reviewer, un altro in attesa. Vuoi che lo legga?"
        )
        #expect(
            VoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 1, languageCode: "de")
                == "Neue Nachricht von Reviewer, 1 weitere wartet. Soll ich sie vorlesen?"
        )
        #expect(
            VoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 3, languageCode: "fr")
                == "Nouveau message de Reviewer, 3 autres en attente. Voulez-vous que je le lise ?"
        )
        #expect(
            VoiceChatPhrases.announcement(sender: "coordinator", isBroadcast: false, remaining: 1, languageCode: "en")
                == "New message from coordinator, 1 more waiting. Do you want me to read it?"
        )
        #expect(
            VoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: true, remaining: 0, languageCode: "ja")
                == "New message from Reviewer to all. Do you want me to read it?"
        )
        #expect(
            VoiceChatPhrases.announcement(sender: "Reviewer", isBroadcast: false, remaining: 0, languageCode: nil)
                == "New message from Reviewer. Do you want me to read it?"
        )
    }
}
