//
//  TerminalMarkdownInlineSpanStreamingTests.swift
//  ZenCODE
//
//  Early emission of closed inline constructs on a pending prose line.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

/// Coverage for streaming a pending prose tail once its markers form closed
/// inline constructs (`code`, **bold**, *italic*, ~~strike~~, links), and for
/// the validated continuation of a line committed that way. Early emission
/// changes only *when* text appears: the concatenated output of a line must be
/// byte-identical whatever the delta split.
///
/// The `whole` literals were captured with whole-line delivery before early
/// inline emission existed. `preexistingSplit` records lines whose split
/// delivery already differed from whole-line delivery at that time, because
/// the raw prose prefix before the first marker bypasses the parser (smart
/// punctuation, entities, escapes, images). Those lines stay out of the
/// equivalence property and are pinned to that earlier split output instead.
@Suite
struct TerminalMarkdownInlineSpanStreamingTests {
    struct Sample: CustomTestStringConvertible, Sendable {
        let line: String
        let whole: String
        var wholeSanitized: String?
        var preexistingSplit: String?

        init(
            _ line: String,
            whole: String,
            wholeSanitized: String? = nil,
            preexistingSplit: String? = nil
        ) {
            self.line = line
            self.whole = whole
            self.wholeSanitized = wholeSanitized
            self.preexistingSplit = preexistingSplit
        }

        var testDescription: String {
            String(line.debugDescription.prefix(72))
        }

        func expectedWhole(sanitizing: Bool) -> String {
            sanitizing ? wholeSanitized ?? whole : whole
        }

        func expectedSplit(sanitizing: Bool) -> String {
            preexistingSplit ?? expectedWhole(sanitizing: sanitizing)
        }
    }

    static let longCommittedLine = "**Nota:** a < b "
        + String(repeating: "parola l'altra e it's ", count: 14) + "fine"
    static let longPlainLine = "Prefisso `x` "
        + String(repeating: "testo semplice senza marcatori ", count: 12) + "fine"

    static let samples: [Sample] = [
        Sample(
            "Usa `foo` e **bar** poi altro",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mfoo\u{1B}[0m e \u{1B}[1mbar\u{1B}[0m poi altro\n"
        ),
        Sample(
            "Testo con *corsivo* e _corsivo_ qui",
            whole: "Testo con \u{1B}[3mcorsivo\u{1B}[0m e \u{1B}[3mcorsivo\u{1B}[0m qui\n"
        ),
        Sample(
            "Barrato ~~vecchio~~ e ~tilde~ fine",
            whole: "Barrato \u{1B}[9mvecchio\u{1B}[0m e \u{1B}[9mtilde\u{1B}[0m fine\n"
        ),
        Sample(
            "Leggi [la guida](https://example.com/a_b) per dettagli",
            whole: "Leggi \u{1B}[38;5;75mla guida\u{1B}[0m \u{1B}[90m<https://example.com/a_b>\u{1B}[0m per dettagli\n"
        ),
        Sample(
            "**Nota:** testo semplice dopo il grassetto",
            whole: "\u{1B}[1mNota:\u{1B}[0m testo semplice dopo il grassetto\n"
        ),
        Sample(
            "**Nota:** l'utente vede _questo_ e `x` subito",
            whole: "\u{1B}[1mNota:\u{1B}[0m l\u{2019}utente vede \u{1B}[3mquesto\u{1B}[0m e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m subito\n"
        ),
        Sample(
            "Emoji \u{1F44D}\u{1F3FD} vicino a **bold**\u{1F44D} e `code`\u{1F1EE}\u{1F1F9} fine",
            whole: "Emoji \u{1F44D}\u{1F3FD} vicino a \u{1B}[1mbold\u{1B}[0m\u{1F44D} e \u{1B}[48;5;236m\u{1B}[38;5;180mcode\u{1B}[0m\u{1F1EE}\u{1F1F9} fine\n"
        ),
        Sample(
            "Combinanti cafe\u{301} **e\u{301}** e `n\u{303}` poi",
            whole: "Combinanti cafe\u{301} \u{1B}[1me\u{301}\u{1B}[0m e \u{1B}[48;5;236m\u{1B}[38;5;180mn\u{303}\u{1B}[0m poi\n"
        ),
        Sample(
            "Il calcolo 2 * 3 fa 6 e **ok** dopo",
            whole: "Il calcolo 2 * 3 fa 6 e \u{1B}[1mok\u{1B}[0m dopo\n"
        ),
        Sample(
            "Usa snake_case e `x` dopo",
            whole: "Usa snake_case e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m dopo\n"
        ),
        Sample(
            "Lista [x] senza link e `y`",
            whole: "Lista [x] senza link e \u{1B}[48;5;236m\u{1B}[38;5;180my\u{1B}[0m\n"
        ),
        Sample(
            "Confronto a < b con `z` e **w**",
            whole: "Confronto a < b con \u{1B}[48;5;236m\u{1B}[38;5;180mz\u{1B}[0m e \u{1B}[1mw\u{1B}[0m\n"
        ),
        Sample(
            "Escape \\*non corsivo\\* e `c`",
            whole: "Escape *non corsivo* e \u{1B}[48;5;236m\u{1B}[38;5;180mc\u{1B}[0m\n",
            preexistingSplit: "Escape \\*non corsivo* e \u{1B}[48;5;236m\u{1B}[38;5;180mc\u{1B}[0m\n"
        ),
        Sample(
            "Pipe a | b con `p` e **q**",
            whole: "Pipe a | b con \u{1B}[48;5;236m\u{1B}[38;5;180mp\u{1B}[0m e \u{1B}[1mq\u{1B}[0m\n"
        ),
        Sample(
            "'parole tra apici' e `x` dopo 'altre parole' qui",
            whole: "\u{2018}parole tra apici\u{2019} e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m dopo \u{2018}altre parole\u{2019} qui\n",
            preexistingSplit: "'parole tra apici' e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m dopo \u{2018}altre parole\u{2019} qui\n"
        ),
        Sample(
            "Dice \"parole tra virgolette\" e **x** poi \"ancora qui\" fine",
            whole: "Dice \u{201C}parole tra virgolette\u{201D} e \u{1B}[1mx\u{1B}[0m poi \u{201C}ancora qui\u{201D} fine\n",
            preexistingSplit: "Dice \"parole tra virgolette\" e \u{1B}[1mx\u{1B}[0m poi \u{201C}ancora qui\u{201D} fine\n"
        ),
        Sample(
            "Usa `x`, it's ok e l'altro pure",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m, it\u{2019}s ok e l\u{2019}altro pure\n"
        ),
        Sample(
            "Trattino -- e puntini... dopo `x` -- e ... fine",
            whole: "Trattino \u{2013} e puntini\u{2026} dopo \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m \u{2013} e \u{2026} fine\n",
            preexistingSplit: "Trattino -- e puntini... dopo \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m \u{2013} e \u{2026} fine\n"
        ),
        Sample(
            "`codice` all'inizio e poi testo",
            whole: "\u{1B}[48;5;236m\u{1B}[38;5;180mcodice\u{1B}[0m all\u{2019}inizio e poi testo\n"
        ),
        Sample(
            "*corsivo* iniziale e altro",
            whole: "\u{1B}[3mcorsivo\u{1B}[0m iniziale e altro\n"
        ),
        Sample(
            "~~barrato~~ iniziale e altro",
            whole: "\u{1B}[9mbarrato\u{1B}[0m iniziale e altro\n"
        ),
        Sample(
            "[link](https://x.y) iniziale e altro",
            whole: "\u{1B}[38;5;75mlink\u{1B}[0m \u{1B}[90m<https://x.y>\u{1B}[0m iniziale e altro\n"
        ),
        Sample(
            "_corsivo_ iniziale e altro",
            whole: "\u{1B}[3mcorsivo\u{1B}[0m iniziale e altro\n"
        ),
        Sample(
            "***grassetto corsivo*** e testo",
            whole: "\u{1B}[3m\u{1B}[1mgrassetto corsivo\u{1B}[0m\u{1B}[3m\u{1B}[0m e testo\n"
        ),
        Sample(
            "**a** **b** **c** fine",
            whole: "\u{1B}[1ma\u{1B}[0m \u{1B}[1mb\u{1B}[0m \u{1B}[1mc\u{1B}[0m fine\n"
        ),
        Sample(
            "Aperto **senza chiusura e `x` dopo",
            whole: "Aperto **senza chiusura e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m dopo\n",
            wholeSanitized: "Aperto senza chiusura e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m dopo\n"
        ),
        Sample(
            "Testo **chiuso** e poi **aperto senza chiusura",
            whole: "Testo \u{1B}[1mchiuso\u{1B}[0m e poi **aperto senza chiusura\n",
            wholeSanitized: "Testo \u{1B}[1mchiuso\u{1B}[0m e poi aperto senza chiusura\n"
        ),
        Sample(
            "**Inizio aperto e poi `x`",
            whole: "**Inizio aperto e poi \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m\n",
            wholeSanitized: "Inizio aperto e poi \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m\n"
        ),
        Sample(
            "Doppio ``a`b`` code e `c`",
            whole: "Doppio \u{1B}[48;5;236m\u{1B}[38;5;180ma`b\u{1B}[0m code e \u{1B}[48;5;236m\u{1B}[38;5;180mc\u{1B}[0m\n"
        ),
        Sample(
            "Con spazi  doppi `x`  dopo\te **b**\tfine",
            whole: "Con spazi  doppi \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m  dopo\te \u{1B}[1mb\u{1B}[0m\tfine\n"
        ),
        Sample(
            "Immagine ![alt](img.png) e `x` dopo",
            whole: "Immagine \u{1B}[90m\u{1F5BC} alt <img.png>\u{1B}[0m e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m dopo\n",
            preexistingSplit: "Immagine !\u{1B}[38;5;75malt\u{1B}[0m \u{1B}[90m<img.png>\u{1B}[0m e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m dopo\n"
        ),
        Sample(
            "Entit\u{E0} &amp; e `x` &copy; fine",
            whole: "Entit\u{E0} & e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m \u{A9} fine\n",
            preexistingSplit: "Entit\u{E0} &amp; e \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m \u{A9} fine\n"
        ),
        Sample(
            "Parentesi (**b**) e (`c`) fine",
            whole: "Parentesi (\u{1B}[1mb\u{1B}[0m) e (\u{1B}[48;5;236m\u{1B}[38;5;180mc\u{1B}[0m) fine\n"
        ),
        Sample(
            "**\"q\"** inizio con virgolette",
            whole: "\u{1B}[1m\u{201C}q\u{201D}\u{1B}[0m inizio con virgolette\n"
        ),
        Sample(
            "Fine riga con `x` e spazio ",
            whole: "Fine riga con \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e spazio\n"
        ),
        Sample(
            "Usa `foo` e _bar_ ok",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mfoo\u{1B}[0m e \u{1B}[3mbar\u{1B}[0m ok\n"
        ),
        Sample(
            "**Nota:** see _this_ x",
            whole: "\u{1B}[1mNota:\u{1B}[0m see \u{1B}[3mthis\u{1B}[0m x\n"
        ),
        Sample(
            "Pre `a` mezzo `b` e 'apice aperto e `c` fine",
            whole: "Pre \u{1B}[48;5;236m\u{1B}[38;5;180ma\u{1B}[0m mezzo \u{1B}[48;5;236m\u{1B}[38;5;180mb\u{1B}[0m e \u{2019}apice aperto e \u{1B}[48;5;236m\u{1B}[38;5;180mc\u{1B}[0m fine\n"
        ),
        Sample(
            "Pre `a` e 'citazione chiusa' poi `b` fine",
            whole: "Pre \u{1B}[48;5;236m\u{1B}[38;5;180ma\u{1B}[0m e \u{2018}citazione chiusa\u{2019} poi \u{1B}[48;5;236m\u{1B}[38;5;180mb\u{1B}[0m fine\n"
        ),
        Sample(
            "**added `Sources/a.swift`**  +3 -1",
            whole: "\u{1B}[1madded \u{1B}[48;5;236m\u{1B}[38;5;180mSources/a.swift\u{1B}[0m\u{1B}[1m\u{1B}[0m  \u{1B}[38;5;114m+3\u{1B}[0m \u{1B}[38;5;210m-1\u{1B}[0m\n"
        ),
        Sample(
            "- elenco con `x` e **b**",
            whole: "\u{1B}[38;5;244m\u{2022}\u{1B}[0m elenco con \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[1mb\u{1B}[0m\n"
        ),
        Sample(
            "> citazione con **b** e altro",
            whole: "\u{1B}[38;5;108m\u{258C}\u{1B}[0m \u{1B}[90mcitazione con \u{1B}[1mb\u{1B}[0m\u{1B}[90m e altro\u{1B}[0m\n"
        ),
        Sample(
            "# Titolo con `x` e altro",
            whole: "\u{1B}[1;38;5;81mTitolo con \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m\u{1B}[1;38;5;81m e altro\u{1B}[0m\n"
        ),
        Sample(
            "1. ordinato con **b** e altro",
            whole: "\u{1B}[38;5;244m1.\u{1B}[0m ordinato con \u{1B}[1mb\u{1B}[0m e altro\n"
        ),
        Sample(
            "| a | b |",
            whole: "| a | b |\n"
        ),
        Sample(
            "**Nota:** 'parole tra apici' e \"parole tra virgolette\" -- poi... fine",
            whole: "\u{1B}[1mNota:\u{1B}[0m \u{2018}parole tra apici\u{2019} e \u{201C}parole tra virgolette\u{201D} \u{2013} poi\u{2026} fine\n"
        ),
        Sample(
            "Usa `x` e \"parole tra virgolette\" e 'parole tra apici' ok",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{201C}parole tra virgolette\u{201D} e \u{2018}parole tra apici\u{2019} ok\n"
        ),
        Sample(
            "`x` -- e puntini... e `y` fine",
            whole: "\u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m \u{2013} e puntini\u{2026} e \u{1B}[48;5;236m\u{1B}[38;5;180my\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` e 'l'altro' ok",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{2018}l\u{2019}altro\u{2019} ok\n"
        ),
        Sample(
            "Usa `x` e \"aperta senza chiusura e `y` fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{201C}aperta senza chiusura e \u{1B}[48;5;236m\u{1B}[38;5;180my\u{1B}[0m fine\n"
        ),
        Sample(
            "Vedi [il 'manuale'](https://x.y) e `z` ok",
            whole: "Vedi \u{1B}[38;5;75mil \u{2018}manuale\u{2019}\u{1B}[0m \u{1B}[90m<https://x.y>\u{1B}[0m e \u{1B}[48;5;236m\u{1B}[38;5;180mz\u{1B}[0m ok\n"
        ),
        Sample(
            "Usa `x` e *'citazione*' poi",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[3m\u{2019}citazione\u{1B}[0m\u{2019} poi\n"
        ),
        Sample(
            "Usa `x` e **a *b* c** fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[1ma \u{1B}[3mb\u{1B}[0m\u{1B}[1m c\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` e *a **b** c* fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[3ma \u{1B}[1mb\u{1B}[0m\u{1B}[3m c\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` e ***a** b* fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[3m\u{1B}[1ma\u{1B}[0m\u{1B}[3m b\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` e **a**b** c fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[1ma\u{1B}[0mb** c fine\n",
            wholeSanitized: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[1ma\u{1B}[0mb c fine\n"
        ),
        Sample(
            "Usa `x` e *a*b* fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[3ma\u{1B}[0mb* fine\n"
        ),
        Sample(
            "Usa `x` e __a__ e __b__x fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[1ma\u{1B}[0m e __b__x fine\n"
        ),
        Sample(
            "Usa `x` e ~a~ ~~b~~ ~~~c~~~ fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[9ma\u{1B}[0m \u{1B}[9mb\u{1B}[0m ~~~c~~~ fine\n"
        ),
        Sample(
            "Usa `x` e [link *it*](https://x.y/a_b) [ref] fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[38;5;75mlink \u{1B}[3mit\u{1B}[0m\u{1B}[38;5;75m\u{1B}[0m \u{1B}[90m<https://x.y/a_b>\u{1B}[0m [ref] fine\n"
        ),
        Sample(
            "Usa `x` e [a [b](c) d](e) fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e [a \u{1B}[38;5;75mb\u{1B}[0m \u{1B}[90m<c>\u{1B}[0m d](e) fine\n"
        ),
        Sample(
            "Usa `x` e ![img *a*](i.png) fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[90m\u{1F5BC} img \u{1B}[3ma\u{1B}[0m <i.png>\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` e `` a ` b `` e ``` c ``` fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[48;5;236m\u{1B}[38;5;180ma ` b\u{1B}[0m e \u{1B}[48;5;236m\u{1B}[38;5;180mc\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` e (`a`) [`b`](c) fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e (\u{1B}[48;5;236m\u{1B}[38;5;180ma\u{1B}[0m) \u{1B}[38;5;75m\u{1B}[48;5;236m\u{1B}[38;5;180mb\u{1B}[0m\u{1B}[38;5;75m\u{1B}[0m \u{1B}[90m<c>\u{1B}[0m fine\n"
        ),
        Sample(
            "**bold**: `x` e _y_ fine",
            whole: "\u{1B}[1mbold\u{1B}[0m: \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[3my\u{1B}[0m fine\n"
        ),
        Sample(
            "`a`b `c` d",
            whole: "\u{1B}[48;5;236m\u{1B}[38;5;180ma\u{1B}[0mb \u{1B}[48;5;236m\u{1B}[38;5;180mc\u{1B}[0m d\n"
        ),
        Sample(
            "Usa `x`'s e `y` fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m\u{2019}s e \u{1B}[48;5;236m\u{1B}[38;5;180my\u{1B}[0m fine\n"
        ),
        Sample(
            "Il `codice` dell'utente e 'citazione' e \"doppia\" fine",
            whole: "Il \u{1B}[48;5;236m\u{1B}[38;5;180mcodice\u{1B}[0m dell\u{2019}utente e \u{2018}citazione\u{2019} e \u{201C}doppia\u{201D} fine\n"
        ),
        Sample(
            "Usa `x` e &amp; &copy; fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e & \u{A9} fine\n"
        ),
        Sample(
            "Usa `x` e www.example.com e mail@example.com fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e www.example.com e mail@example.com fine\n"
        ),
        Sample(
            "Usa `x` e -- e --- e ... fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{2013} e \u{2014} e \u{2026} fine\n"
        ),
        Sample(
            "Usa `x` e fine\t",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e fine\n"
        ),
        Sample(
            "Usa `x`\u{A0}e **b** fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m\u{A0}e \u{1B}[1mb\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` \u{1F468}\u{200D}\u{1F469} e **b** fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m \u{1F468}\u{200D}\u{1F469} e \u{1B}[1mb\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` \u{301}e fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m \u{301}e fine\n"
        ),
        Sample(
            "  **x** y `z` fine",
            whole: "  \u{1B}[1mx\u{1B}[0m y \u{1B}[48;5;236m\u{1B}[38;5;180mz\u{1B}[0m fine\n"
        ),
        Sample(
            "Pensiero **a** poi **b",
            whole: "Pensiero \u{1B}[1ma\u{1B}[0m poi **b\n",
            wholeSanitized: "Pensiero \u{1B}[1ma\u{1B}[0m poi b\n"
        ),
        Sample(
            "Usa `x` e **b**, poi *c*; e ~~d~~. fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[1mb\u{1B}[0m, poi \u{1B}[3mc\u{1B}[0m; e \u{1B}[9md\u{1B}[0m. fine\n"
        ),
        Sample(
            "Usa `x` e [t](u \"titolo\") fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[38;5;75mt\u{1B}[0m \u{1B}[90m<u>\u{1B}[0m fine\n"
        ),
        Sample(
            "Usa `x` e [t](u(v)w) fine",
            whole: "Usa \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m e \u{1B}[38;5;75mt\u{1B}[0m \u{1B}[90m<u(v)w>\u{1B}[0m fine\n"
        ),
        Sample(
            "*a* `b` **c** ~~d~~ [e](f) fine",
            whole: "\u{1B}[3ma\u{1B}[0m \u{1B}[48;5;236m\u{1B}[38;5;180mb\u{1B}[0m \u{1B}[1mc\u{1B}[0m \u{1B}[9md\u{1B}[0m \u{1B}[38;5;75me\u{1B}[0m \u{1B}[90m<f>\u{1B}[0m fine\n"
        ),
        Sample(
            "**Nome** | Valore",
            whole: "\u{1B}[1mNome\u{1B}[0m | Valore\n"
        ),
        Sample(
            Self.longCommittedLine,
            whole: "\u{1B}[1mNota:\u{1B}[0m a < b parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s parola l\u{2019}altra e it\u{2019}s fine\n"
        ),
        Sample(
            Self.longPlainLine,
            whole: "Prefisso \u{1B}[48;5;236m\u{1B}[38;5;180mx\u{1B}[0m testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori testo semplice senza marcatori fine\n"
        ),
    ]

    static var equivalentSamples: [Sample] {
        samples.filter { $0.preexistingSplit == nil }
    }

    static var preexistingDivergentSamples: [Sample] {
        samples.filter { $0.preexistingSplit != nil }
    }

    // MARK: Helpers

    private static func makeFormatter(sanitizing: Bool = false) -> TerminalMarkdownStreamFormatter {
        TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: sanitizing,
            palette: .dark
        )
    }

    private static func deliver(_ deltas: [String], sanitizing: Bool = false) -> String {
        var formatter = makeFormatter(sanitizing: sanitizing)
        var rendered = ""
        for delta in deltas {
            rendered += formatter.consume(delta)
        }
        return rendered + formatter.finish()
    }

    /// Output produced before the newline when `line` arrives one `Character`
    /// at a time.
    private static func outputBeforeNewline(
        _ line: String,
        sanitizing: Bool = false
    ) -> (beforeNewline: String, total: String) {
        var formatter = makeFormatter(sanitizing: sanitizing)
        var before = ""
        for character in line {
            before += formatter.consume(String(character))
        }
        let total = before + formatter.consume("\n") + formatter.finish()
        return (before, total)
    }

    /// Deterministic SplitMix64, so failures are reproducible.
    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// Splits by Unicode scalar, so combining marks, emoji modifiers, ZWJ
    /// sequences and flags can straddle deltas.
    private static func randomScalarChunks(_ text: String, seed: UInt64) -> [String] {
        var generator = SplitMix64(state: seed)
        let scalars = Array(text.unicodeScalars)
        var chunks: [String] = []
        var start = 0
        while start < scalars.count {
            let end = min(scalars.count, start + Int(generator.next() % 8) + 1)
            var chunk = String.UnicodeScalarView()
            chunk.append(contentsOf: scalars[start..<end])
            chunks.append(String(chunk))
            start = end
        }
        return chunks
    }

    private static func splitDeliveries(of text: String) -> [(name: String, deltas: [String])] {
        [
            ("per-character", text.map(String.init)),
            ("per-scalar", text.unicodeScalars.map(String.init))
        ] + (1...6).map { seed in
            ("random-chunks-\(seed)", randomScalarChunks(text, seed: UInt64(seed)))
        }
    }

    // MARK: Characterization and split equivalence

    @Test(arguments: samples)
    func wholeLineOutputMatchesCharacterization(sample: Sample) {
        for sanitizing in [false, true] {
            let rendered = Self.deliver([sample.line + "\n"], sanitizing: sanitizing)
            #expect(
                rendered == sample.expectedWhole(sanitizing: sanitizing),
                "sanitizing: \(sanitizing)"
            )
        }
    }

    @Test(arguments: equivalentSamples)
    func splitDeliveriesAreByteIdenticalToWholeLineDelivery(sample: Sample) {
        let text = sample.line + "\n"
        for sanitizing in [false, true] {
            let whole = Self.deliver([text], sanitizing: sanitizing)
            for split in Self.splitDeliveries(of: text) {
                #expect(
                    Self.deliver(split.deltas, sanitizing: sanitizing) == whole,
                    "\(split.name), sanitizing: \(sanitizing)"
                )
            }
        }
    }

    @Test(arguments: preexistingDivergentSamples)
    func preexistingRawPrefixDivergencesAreUnchanged(sample: Sample) {
        let text = sample.line + "\n"
        for sanitizing in [false, true] {
            for split in Self.splitDeliveries(of: text) {
                #expect(
                    Self.deliver(split.deltas, sanitizing: sanitizing)
                        == sample.expectedSplit(sanitizing: sanitizing),
                    "\(split.name), sanitizing: \(sanitizing)"
                )
            }
        }
    }

    // MARK: Early emission

    @Test
    func closedCodeSpanAndBoldAppearBeforeTheNewline() {
        let result = Self.outputBeforeNewline("Usa `foo` e **bar** poi altro")

        #expect(result.beforeNewline.contains("\u{1B}[48;5;236m\u{1B}[38;5;180mfoo\u{1B}[0m"))
        #expect(result.beforeNewline.contains("\u{1B}[1mbar\u{1B}[0m"))
        #expect(!result.beforeNewline.contains("`"))
        #expect(!result.beforeNewline.contains("*"))
        // The last word stays pending until a boundary or the newline proves
        // it is not the start of another construct.
        #expect(TerminalANSIText.stripANSI(result.beforeNewline) == "Usa foo e bar poi")
        #expect(result.total == Self.deliver(["Usa `foo` e **bar** poi altro\n"]))
    }

    @Test
    func boldLabelAtLineStartStreamsOnceItsBoundaryArrives() {
        var formatter = Self.makeFormatter()

        #expect(formatter.consume("**Nota:**").isEmpty)
        #expect(formatter.consume(" ") == "\u{1B}[1mNota:\u{1B}[0m")
        var rendered = "\u{1B}[1mNota:\u{1B}[0m"
        rendered += formatter.consume("l'utente ")
        #expect(rendered == "\u{1B}[1mNota:\u{1B}[0m l\u{2019}utente")
        rendered += formatter.consume("vede\n") + formatter.finish()
        #expect(rendered == Self.deliver(["**Nota:** l'utente vede\n"]))
    }

    @Test
    func committedLineRendersLaterPiecesThroughTheParser() {
        // Once committed, the rest of the line keeps smart punctuation and
        // flanking of the complete line instead of switching to raw prose.
        let result = Self.outputBeforeNewline("Usa `x` e _bar_, it's -- ok... fine")

        #expect(TerminalANSIText.stripANSI(result.beforeNewline) == "Usa x e bar, it\u{2019}s \u{2013} ok\u{2026}")
        #expect(result.beforeNewline.contains("\u{1B}[3mbar\u{1B}[0m"))
        #expect(result.total == Self.deliver(["Usa `x` e _bar_, it's -- ok... fine\n"]))
    }

    @Test
    func finishRendersACommittedTailThroughTheParser() {
        var formatter = Self.makeFormatter()
        var rendered = ""
        for character in "Usa `x` e l'altro" {
            rendered += formatter.consume(String(character))
        }
        rendered += formatter.finish()

        #expect(TerminalANSIText.stripANSI(rendered) == "Usa x e l\u{2019}altro")
        #expect(rendered + "\n" == Self.deliver(["Usa `x` e l'altro\n"]))
    }

    // MARK: Conservative fallbacks

    @Test(arguments: [
        ("Il calcolo 2 * 3 fa **ok** dopo", "Il calcolo 2 "),
        ("Usa snake_case e `x` dopo", "Usa snake"),
        ("Lista [x] senza link e `y`", "Lista "),
        ("Confronto a < b con `z` e **w**", "Confronto a "),
        ("Escape `x` \\*non\\* e `c` dopo", "Escape x"),
        ("Pipe a | b con `p` e **q**", "Pipe a "),
        ("Aperto **senza chiusura e `x` dopo", "Aperto "),
        ("Codice `aperto e **b** dopo", "Codice "),
        ("_corsivo_ iniziale e `x` dopo", ""),
        ("***a*** e `x` dopo", ""),
        ("**\"q\"** e `x` dopo", ""),
        ("* elenco con `x` e **b** dopo", ""),
        ("~~~ `x` e altro", ""),
        ("| `a` | b e **c** dopo", "")
    ])
    func unsafePrefixKeepsTodaysBuffering(line: String, expectedBeforeNewline: String) {
        let result = Self.outputBeforeNewline(line)

        #expect(TerminalANSIText.stripANSI(result.beforeNewline) == expectedBeforeNewline)
        #expect(result.total == Self.deliver([line + "\n"]))
    }

    @Test
    func openingQuoteKeepsTheBoundaryClosedUntilItsCloser() {
        let open = Self.outputBeforeNewline("Pre `a` e 'apice aperto e `c` fine")
        #expect(TerminalANSIText.stripANSI(open.beforeNewline) == "Pre a e")

        let closed = Self.outputBeforeNewline("Pre `a` e \"doppie chiuse\" poi `b` fine")
        #expect(TerminalANSIText.stripANSI(closed.beforeNewline) == "Pre a e \u{201C}doppie chiuse\u{201D} poi b")

        let apostrophes = Self.outputBeforeNewline("Pre `a` it's l'altro e po' poi fine")
        #expect(TerminalANSIText.stripANSI(apostrophes.beforeNewline)
            == "Pre a it\u{2019}s l\u{2019}altro e po\u{2019} poi")
    }

    @Test
    func artifactMetadataHeaderIsNotSplitFromItsCounts() {
        let line = "**added `dir/+12 -345 e\u{301}.swift`**  +12 -345"
        var formatter = Self.makeFormatter()
        var before = ""
        for scalar in line.unicodeScalars {
            before += formatter.consume(String(scalar))
        }
        let rendered = before + formatter.consume("\n") + formatter.finish()

        #expect(before.isEmpty)
        let palette = TerminalMarkdownPalette.dark
        #expect(rendered.contains(
            "  \(palette.diffAddition)+12\(TerminalStyle.reset) \(palette.diffRemoval)-345\(TerminalStyle.reset)"
        ))
        #expect(rendered == Self.deliver([line + "\n"]))
    }

    @Test
    func carriageReturnStopsEarlyEmissionAndStaysPartOfTheLineEnding() {
        let line = "Usa `x` e fine\r\n"
        var formatter = Self.makeFormatter()
        var before = ""
        for scalar in line.unicodeScalars.dropLast() {
            before += formatter.consume(String(scalar))
        }
        let rendered = before + formatter.consume("\n") + formatter.finish()

        #expect(TerminalANSIText.stripANSI(before) == "Usa x e")
        #expect(rendered == Self.deliver(["Usa `x` e fine\n"]))
    }

    // MARK: Buffering bounds

    @Test
    func committedLineIsNotFlushedRawAfterTheSoftLimit() {
        let line = Self.longCommittedLine
        #expect(line.unicodeScalars.count > 240)

        let result = Self.outputBeforeNewline(line)

        // The `<` keeps the conservative fallback; the 240-scalar raw flush
        // must not emit the rest unparsed (straight apostrophes).
        #expect(TerminalANSIText.stripANSI(result.beforeNewline) == "Nota: a")
        #expect(result.total == Self.deliver([line + "\n"]))
        #expect(result.total.contains("l\u{2019}altra e it\u{2019}s"))
    }

    @Test
    func hardLimitStillBoundsACommittedLine() {
        let line = "**Nota:** a < b " + String(repeating: "parola ", count: 320)
        let result = Self.outputBeforeNewline(line)

        let visible = TerminalANSIText.stripANSI(result.beforeNewline)
        #expect(visible.hasPrefix("Nota: a < b parola"))
        #expect(visible.unicodeScalars.count > 2_000)
    }

    @Test
    func manySpansOnOneLineStreamWithoutWaitingForTheNewline() {
        let line = String(repeating: "`a` **b** _c_ [d](e) ", count: 200) + "fine"
        let result = Self.outputBeforeNewline(line)

        let visible = TerminalANSIText.stripANSI(result.beforeNewline)
        #expect(visible.hasPrefix(String(repeating: "a b c d <e> ", count: 199)))
        #expect(result.total == Self.deliver([line + "\n"]))
    }
}
