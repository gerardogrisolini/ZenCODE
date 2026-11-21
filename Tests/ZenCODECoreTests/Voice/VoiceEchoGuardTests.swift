//
//  VoiceEchoGuardTests.swift
//  ZenCODECoreTests
//

import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Voice echo guard")
struct VoiceEchoGuardTests {
    /// A reading long enough to hold most common words.
    private let reading = """
    Ho controllato il progetto e tutti i test passano. Il primo problema riguarda la \
    configurazione del server, che non carica il file corretto all'avvio. Il secondo \
    problema è più semplice: manca un controllo sul valore vuoto nella funzione che \
    legge le impostazioni. Ho corretto entrambi e ho aggiunto due verifiche nuove. \
    Adesso vuoi che prepari anche una descrizione per la modifica?
    """

    /// A reading that holds every word of "non voglio questo adesso", each one
    /// far from the others and in a different order.
    private let scatteredReading = """
    Adesso ho controllato il progetto e tutti i test passano senza errori. Il primo \
    difetto riguarda la configurazione del server, che carica il file sbagliato \
    all'avvio e ignora le impostazioni scelte dall'utente. Il secondo difetto è più \
    semplice: manca un controllo sul valore vuoto nella funzione che legge le \
    preferenze, ma per questo basta una riga. Ho corretto entrambi i difetti e ho \
    aggiunto due verifiche nuove, così il comportamento resta stabile anche quando \
    voglio cambiare le impostazioni più avanti. Se pensi che sia tutto a posto posso \
    chiudere qui, altrimenti dimmi cosa guardare; il lavoro non è finito finché non \
    lo confermi.
    """

    @Test
    func aSingleWordIsEchoOnlyWhenTheTextHoldsIt() {
        #expect(VoiceEchoGuard.isLikelyEcho("server", of: reading))
        #expect(!VoiceEchoGuard.isLikelyEcho("pizza", of: reading))
    }

    @Test
    func anInOrderFragmentIsEchoEvenFromTheMiddleOfASentence() {
        #expect(VoiceEchoGuard.isLikelyEcho("server che non carica il file corretto all'avvio", of: reading))
        #expect(VoiceEchoGuard.isLikelyEcho("Il secondo problema è più semplice", of: reading))
    }

    @Test
    func aFragmentWithOneWordInSixMisrecognizedIsEcho() {
        // "valore" heard as "valle".
        #expect(VoiceEchoGuard.isLikelyEcho("manca un controllo sul valle vuoto", of: reading))
    }

    @Test
    func aFragmentWithTwoWordsInSixMisrecognizedIsNotEcho() {
        // "controllo" heard as "contratto" and "valore" as "valle".
        #expect(!VoiceEchoGuard.isLikelyEcho("manca un contratto sul valle vuoto", of: reading))
    }

    @Test
    func aFragmentWithTheFirstWordMisrecognizedIsEcho() {
        // "il" heard as "al": the fragment must still be found from its second word.
        #expect(VoiceEchoGuard.isLikelyEcho("al secondo problema è più semplice", of: reading))
    }

    @Test
    func twoSegmentsFromDistantPointsOfTheTextAreEcho() {
        let first = "la configurazione del server che non carica"
        let second = "ho corretto entrambi e ho aggiunto due verifiche"
        let segments = [first, second].joined(separator: VoiceDictationSegmenter.segmentSeparator)
        #expect(VoiceEchoGuard.isLikelyEcho(segments, of: reading))
        // Read as a single segment, the second fragment is too far from the first.
        #expect(!VoiceEchoGuard.isLikelyEcho(first + " " + second, of: reading))
    }

    @Test
    func wordsScatteredThroughALongTextAreNotEcho() {
        let heard = "non voglio questo adesso"
        let readWords = Set(VoiceEchoGuard.words(in: scatteredReading))
        // Every word of the sentence is somewhere in the text: this is the
        // case a bag-of-words comparison used to discard as echo.
        #expect(VoiceEchoGuard.words(in: heard).allSatisfy(readWords.contains))
        #expect(!VoiceEchoGuard.isLikelyEcho(heard, of: scatteredReading))
    }

    @Test
    func theSameWordsInReverseOrderAreNotEcho() {
        let spoken = "Il server carica correttamente il file di configurazione all'avvio."
        #expect(VoiceEchoGuard.isLikelyEcho("carica correttamente il file di configurazione", of: spoken))
        #expect(!VoiceEchoGuard.isLikelyEcho("configurazione di file il correttamente carica", of: spoken))
    }

    @Test
    func emptyTextsAreNeverEcho() {
        #expect(!VoiceEchoGuard.isLikelyEcho("", of: reading))
        #expect(!VoiceEchoGuard.isLikelyEcho(" \n ", of: reading))
        #expect(!VoiceEchoGuard.isLikelyEcho("...", of: reading))
        #expect(!VoiceEchoGuard.isLikelyEcho("server che non carica", of: ""))
        #expect(!VoiceEchoGuard.isLikelyEcho("server che non carica", of: "... !"))
        #expect(!VoiceEchoGuard.isLikelyEcho("", of: ""))
    }

    @Test
    func caseAccentsAndPunctuationDoNotMatter() {
        let spoken = "Sì, è già pronto: vuoi continuare?"
        #expect(VoiceEchoGuard.isLikelyEcho("SI E GIA PRONTO VUOI CONTINUARE", of: spoken))
        #expect(VoiceEchoGuard.isLikelyEcho("sì... è, già; pronto — vuoi continuare", of: spoken))
        #expect(VoiceEchoGuard.isLikelyEcho("si e gia pronto vuoi continuare", of: spoken.uppercased()))
    }
}
