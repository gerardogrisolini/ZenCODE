//
//  TerminalVoiceChatPhrases.swift
//  ZenCODE
//
//  The spoken side of the live shared chat in voice mode: the yes/no words
//  and "message to …" phrases recognised in six languages whatever the voice
//  language, and the announcements and questions read in that language.
//

import Foundation
import ToolCore

enum TerminalVoiceChatPhrases {
    // MARK: - Yes / no

    /// `true` for a spoken yes, `false` for a spoken no, `nil` for anything
    /// else: "yes, but first…" is not an answer. The whole utterance must be
    /// one known phrase, compared without case, accents or punctuation.
    static func affirmation(in utterance: String) -> Bool? {
        let phrase = normalizedPhrase(utterance)
        guard !phrase.isEmpty else {
            return nil
        }
        if affirmativePhrases.contains(phrase) {
            return true
        }
        if negativePhrases.contains(phrase) {
            return false
        }
        return nil
    }

    /// Letters and digits folded without case or accents, one space between
    /// words: `"D'accordo!"` becomes `"d accordo"`.
    static func normalizedPhrase(_ text: String) -> String {
        TerminalVoiceEchoGuard.words(in: text).joined(separator: " ")
    }

    private static let affirmativePhrases = Set([
        // Italian
        "sì", "si", "certo", "va bene", "d'accordo", "ok", "okay", "leggi", "leggilo", "leggila",
        // English
        "yes", "yeah", "yep", "sure", "please", "yes please", "go ahead", "read it",
        // Spanish
        "sí", "claro", "vale", "léelo",
        // French
        "oui", "ouais", "d'accord", "lis-le",
        // German
        "ja", "jawohl", "klar", "lies vor",
        // Portuguese
        "sim", "pode ler"
    ].map(normalizedPhrase))

    private static let negativePhrases = Set([
        // Italian
        "no", "non ora", "dopo",
        // English
        "nope", "not now", "later",
        // Spanish
        "ahora no", "luego",
        // French
        "non", "pas maintenant", "plus tard",
        // German
        "nein", "nicht jetzt", "später",
        // Portuguese
        "não", "nao", "agora não", "depois"
    ].map(normalizedPhrase))

    // MARK: - "Message to …"

    enum SendTarget: Sendable, Equatable {
        case coordinator
        case all
        /// Everything spoken after the preposition: a name, maybe followed by
        /// the text. Resolved by ``resolveNamedRecipient(remainder:participants:)``.
        case named(remainder: String)
    }

    /// Recognises a leading "send a message to …" phrase in any of the six
    /// languages. For the coordinator and the broadcast the text is what
    /// follows an optional `:`, `,`, `.` or `-`; `nil` text means the phrase
    /// named only the recipient. The reserved words win over an agent with
    /// the same name.
    static func sendRequest(in utterance: String) -> (target: SendTarget, text: String?)? {
        let folded = FoldedText(utterance[...])
        for grammar in sendGrammars {
            if let request = grammar.match(folded) {
                return request
            }
        }
        return nil
    }

    enum NamedRecipient: Sendable, Equatable {
        case agent(AgentSharedChat.Participant, text: String?)
        /// No active agent starts the remainder; the spoken name is reported
        /// back, cut at the first separator and bounded.
        case unknown(spokenName: String)
    }

    static let maximumSpokenNameLength = 60

    /// Matches the longest active agent name at the start of `remainder`,
    /// without case or accents and on a word boundary, so "Reviewer" is not
    /// taken for an agent named "Review". The words of the name may be joined
    /// by any punctuation, so "parser-reviewer" is heard whether the
    /// recognizer writes the hyphen or a space. The text is whatever follows
    /// the name and an optional separator.
    static func resolveNamedRecipient(
        remainder: String,
        participants: [AgentSharedChat.Participant]
    ) -> NamedRecipient {
        let folded = FoldedText(remainder[...])
        var best: (participant: AgentSharedChat.Participant, rest: FoldedText, length: Int)?
        for participant in participants where participant.kind == .agent && participant.isActive {
            let words = TerminalVoiceEchoGuard.words(in: AgentSharedChat.displayName(for: participant))
            guard !words.isEmpty else {
                continue
            }
            let pattern = "^\\s*"
                + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[^\\p{L}\\p{N}]+")
                + "(?![\\p{L}\\p{N}])"
            guard let (rest, length) = folded.suffix(after: pattern) else {
                continue
            }
            if best.map({ length > $0.length }) ?? true {
                best = (participant, rest, length)
            }
        }
        if let best {
            return .agent(best.participant, text: messageText(best.rest.original))
        }
        return .unknown(spokenName: spokenName(in: remainder))
    }

    /// The spoken name up to the first separator: `:` and `,` always end it,
    /// `.` and `-` only before a space or at the end, so "parser-reviewer"
    /// and "v1.2" stay whole.
    private static func spokenName(in remainder: String) -> String {
        var name = ""
        var index = remainder.startIndex
        while index < remainder.endIndex {
            let character = remainder[index]
            let next = remainder.index(after: index)
            if character == ":" || character == "," {
                break
            }
            if character == "." || character == "-",
               next == remainder.endIndex || remainder[next].isWhitespace {
                break
            }
            name.append(character)
            index = next
        }
        return String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumSpokenNameLength))
    }

    private static let separators: Set<Character> = [":", ",", ".", "-"]

    /// The message text after an optional separator; `nil` when nothing is
    /// left.
    private static func messageText(_ text: Substring) -> String? {
        var text = text.drop(while: \.isWhitespace)
        if let first = text.first, separators.contains(first) {
            text = text.dropFirst()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    /// One language's "send a message to …" phrase, as regular-expression
    /// fragments matched against the folded utterance.
    private struct SendGrammar {
        /// Optional verb, optional article and the noun; English and German
        /// also put their fixed preposition here.
        let prefix: String
        let coordinator: String
        let all: String
        /// The preposition before a spoken name, when the language has one.
        let named: String?

        func match(_ utterance: FoldedText) -> (target: SendTarget, text: String?)? {
            guard let (rest, _) = utterance.suffix(after: "^\\s*(?:\(prefix))\\s+") else {
                return nil
            }
            if let (text, _) = rest.suffix(after: "^(?:\(coordinator))(?![\\p{L}\\p{N}])") {
                return (.coordinator, messageText(text.original))
            }
            if let (text, _) = rest.suffix(after: "^(?:\(all))(?![\\p{L}\\p{N}])") {
                return (.all, messageText(text.original))
            }
            let remainder: FoldedText
            if let named {
                guard let (afterPreposition, _) = rest.suffix(after: "^(?:\(named))\\s+") else {
                    return nil
                }
                remainder = afterPreposition
            } else {
                remainder = rest
            }
            guard let name = remainder.original.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
                return nil
            }
            return (.named(remainder: name), nil)
        }
    }

    private static let sendGrammars: [SendGrammar] = [
        // English
        SendGrammar(
            prefix: "(?:send\\s+(?:a\\s+)?)?message\\s+to",
            coordinator: "(?:the\\s+)?coordinator",
            all: "all|everyone|everybody",
            named: nil
        ),
        // Italian
        SendGrammar(
            prefix: "(?:(?:invia|manda)\\s+)?(?:un\\s+)?messaggio",
            coordinator: "al\\s+coordinatore",
            all: "a\\s+tutti",
            named: "a"
        ),
        // Spanish
        SendGrammar(
            prefix: "(?:(?:envia|manda)\\s+)?(?:un\\s+)?mensaje",
            coordinator: "al\\s+coordinador",
            all: "a\\s+todos",
            named: "a"
        ),
        // French
        SendGrammar(
            prefix: "(?:envoie\\s+(?:un\\s+)?)?message",
            coordinator: "au\\s+coordinateur",
            all: "a\\s+tous",
            named: "a"
        ),
        // German
        SendGrammar(
            prefix: "(?:(?:sende|schicke?)\\s+)?(?:eine\\s+)?nachricht\\s+an",
            coordinator: "(?:den\\s+)?koordinator",
            all: "alle",
            named: nil
        ),
        // Portuguese
        SendGrammar(
            prefix: "(?:(?:envia|manda)\\s+)?(?:uma\\s+)?mensagem",
            coordinator: "(?:ao|para\\s+o)\\s+coordenador",
            all: "(?:a|para)\\s+todos",
            named: "(?:a|para)"
        )
    ]

    /// Text folded without case or accents for matching, keeping for every
    /// folded scalar the position of the original character so the matched
    /// remainder can be returned as it was spoken.
    private struct FoldedText {
        let original: Substring
        let folded: String
        /// Original index of each scalar of `folded`.
        private let originalIndices: [Substring.Index]

        init(_ original: Substring) {
            var folded = ""
            var indices: [Substring.Index] = []
            var index = original.startIndex
            while index < original.endIndex {
                let next = original.index(after: index)
                let piece = String(original[index..<next])
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                for _ in piece.unicodeScalars {
                    indices.append(index)
                }
                folded += piece
                index = next
            }
            self.original = original
            self.folded = folded
            originalIndices = indices
        }

        /// The text after a match of `pattern` anchored at the start, with the
        /// match length in folded scalars; `nil` without a match.
        func suffix(after pattern: String) -> (rest: FoldedText, length: Int)? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: folded,
                      range: NSRange(folded.startIndex..., in: folded)
                  ),
                  let range = Range(match.range, in: folded) else {
                return nil
            }
            let length = folded.unicodeScalars.distance(from: range.lowerBound, to: range.upperBound)
            let end = folded.unicodeScalars.distance(from: folded.startIndex, to: range.upperBound)
            let originalStart = end < originalIndices.count ? originalIndices[end] : original.endIndex
            return (FoldedText(original[originalStart...]), length)
        }
    }

    // MARK: - Spoken texts

    /// "New message from X[ to all][, N more waiting]. Do you want me to read it?"
    static func announcement(
        sender: String,
        isBroadcast: Bool,
        remaining: Int,
        languageCode: String?
    ) -> String {
        var text = TerminalVoiceSpeechText.localized(announcementFrom, languageCode: languageCode)
            .replacingOccurrences(of: "{sender}", with: sender)
        if isBroadcast {
            text += TerminalVoiceSpeechText.localized(announcementToAll, languageCode: languageCode)
        }
        if remaining == 1 {
            text += TerminalVoiceSpeechText.localized(announcementOneWaiting, languageCode: languageCode)
        } else if remaining > 1 {
            text += TerminalVoiceSpeechText.localized(announcementWaiting, languageCode: languageCode)
                .replacingOccurrences(of: "{n}", with: String(remaining))
        }
        return text + TerminalVoiceSpeechText.localized(announcementQuestion, languageCode: languageCode)
    }

    /// The whole message followed by "Do you want to reply?".
    static func readAloud(text: String, languageCode: String?) -> String {
        let question = TerminalVoiceSpeechText.localized(replyQuestions, languageCode: languageCode)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else {
            return question
        }
        return text + (".!?".contains(last) ? " " : ". ") + question
    }

    static func replyPrompt(languageCode: String?) -> String {
        TerminalVoiceSpeechText.localized(replyPrompts, languageCode: languageCode)
    }

    static func messagePrompt(languageCode: String?) -> String {
        TerminalVoiceSpeechText.localized(messagePrompts, languageCode: languageCode)
    }

    static func sent(languageCode: String?) -> String {
        TerminalVoiceSpeechText.localized(sentNotices, languageCode: languageCode)
    }

    static func sendFailed(languageCode: String?) -> String {
        TerminalVoiceSpeechText.localized(sendFailedNotices, languageCode: languageCode)
    }

    static func agentInactive(name: String, languageCode: String?) -> String {
        TerminalVoiceSpeechText.localized(agentInactiveNotices, languageCode: languageCode)
            .replacingOccurrences(of: "{name}", with: name)
    }

    static func unknownAgent(name: String, languageCode: String?) -> String {
        TerminalVoiceSpeechText.localized(unknownAgentNotices, languageCode: languageCode)
            .replacingOccurrences(of: "{name}", with: name)
    }

    private static let announcementFrom: [String: String] = [
        "en": "New message from {sender}",
        "it": "Nuovo messaggio da {sender}",
        "es": "Nuevo mensaje de {sender}",
        "fr": "Nouveau message de {sender}",
        "de": "Neue Nachricht von {sender}",
        "pt": "Nova mensagem de {sender}"
    ]

    private static let announcementToAll: [String: String] = [
        "en": " to all",
        "it": " a tutti",
        "es": " a todos",
        "fr": " à tous",
        "de": " an alle",
        "pt": " para todos"
    ]

    private static let announcementOneWaiting: [String: String] = [
        "en": ", 1 more waiting",
        "it": ", un altro in attesa",
        "es": ", 1 más en espera",
        "fr": ", 1 autre en attente",
        "de": ", 1 weitere wartet",
        "pt": ", mais 1 à espera"
    ]

    private static let announcementWaiting: [String: String] = [
        "en": ", {n} more waiting",
        "it": ", altri {n} in attesa",
        "es": ", {n} más en espera",
        "fr": ", {n} autres en attente",
        "de": ", {n} weitere warten",
        "pt": ", mais {n} à espera"
    ]

    private static let announcementQuestion: [String: String] = [
        "en": ". Do you want me to read it?",
        "it": ". Vuoi che lo legga?",
        "es": ". ¿Quieres que lo lea?",
        "fr": ". Voulez-vous que je le lise ?",
        "de": ". Soll ich sie vorlesen?",
        "pt": ". Queres que eu a leia?"
    ]

    private static let replyQuestions: [String: String] = [
        "en": "Do you want to reply?",
        "it": "Vuoi rispondere?",
        "es": "¿Quieres responder?",
        "fr": "Voulez-vous répondre ?",
        "de": "Möchtest du antworten?",
        "pt": "Queres responder?"
    ]

    private static let replyPrompts: [String: String] = [
        "en": "Tell me your reply.",
        "it": "Dimmi la risposta.",
        "es": "Dime la respuesta.",
        "fr": "Dites-moi la réponse.",
        "de": "Sag mir die Antwort.",
        "pt": "Diz-me a resposta."
    ]

    private static let messagePrompts: [String: String] = [
        "en": "Tell me the message.",
        "it": "Dimmi il messaggio.",
        "es": "Dime el mensaje.",
        "fr": "Dites-moi le message.",
        "de": "Sag mir die Nachricht.",
        "pt": "Diz-me a mensagem."
    ]

    private static let sentNotices: [String: String] = [
        "en": "Sent.",
        "it": "Inviato.",
        "es": "Enviado.",
        "fr": "Envoyé.",
        "de": "Gesendet.",
        "pt": "Enviado."
    ]

    private static let sendFailedNotices: [String: String] = [
        "en": "Sending failed.",
        "it": "Invio non riuscito.",
        "es": "No se pudo enviar.",
        "fr": "L'envoi a échoué.",
        "de": "Senden fehlgeschlagen.",
        "pt": "O envio falhou."
    ]

    private static let agentInactiveNotices: [String: String] = [
        "en": "{name} is no longer active.",
        "it": "{name} non è più attivo.",
        "es": "{name} ya no está activo.",
        "fr": "{name} n'est plus actif.",
        "de": "{name} ist nicht mehr aktiv.",
        "pt": "{name} já não está ativo."
    ]

    private static let unknownAgentNotices: [String: String] = [
        "en": "No active agent is named {name}.",
        "it": "Nessun agente attivo si chiama {name}.",
        "es": "Ningún agente activo se llama {name}.",
        "fr": "Aucun agent actif ne s'appelle {name}.",
        "de": "Kein aktiver Agent heißt {name}.",
        "pt": "Nenhum agente ativo se chama {name}."
    ]
}
