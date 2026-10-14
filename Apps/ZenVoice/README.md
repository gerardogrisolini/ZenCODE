# ZenVoice (prima versione personale)

App **separata** SwiftUI, solo status bar (`MenuBarExtra`, `LSUIElement`), per macOS **14.0 o successivo**. Nessuna finestra principale o icona Dock: configurazione riapribile dal menu e modale di conferma per i permessi subscription. Nessuna dipendenza da `ZenCODECore`, dal package root o da SDK audio terzi. Il progetto Xcode include Swift 6 language mode, strict concurrency e `MemberImportVisibility`.

## Build e test isolati

Dalla radice del repository, con Xcode selezionato tramite `xcode-select` (ambiente previsto: Xcode 27 / Apple Swift 6.4 / SDK macOS 27):

```sh
xcodebuild -project Apps/ZenVoice/ZenVoice.xcodeproj -scheme ZenVoice \
  -configuration Release -derivedDataPath /tmp/ZenVoice-Build \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Apps/ZenVoice/ZenVoice.xcodeproj -scheme ZenVoice \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/ZenVoice-Tests CODE_SIGNING_ALLOWED=NO test

git diff --check -- Apps/ZenVoice CHANGELOG.md
```

**Stato di verifica:** build e test offline di app e bridge; il collaudo audio interattivo della nuova integrazione subscription richiede ancora l'utente (nessuna attivazione automatica). Il test target è **unhosted**: compila direttamente i componenti di protocollo, non avvia `ZenVoice.app` e non include `@main`, `AudioIO` o `VoiceModel`. Swift Testing esercita le policy condivise di playback, barge-in, follow-up, consensi e shutdown; una shell ACP fake in directory temporanea UUID verifica realmente initialize frammentato con stdout aperto, prompt e permission roundtrip. Nessun provider, API key, Keychain, microfono o rete nei test.

Il bundle non firmato serve solo al controllo di compilazione. Per uso personale aprire `ZenVoice.xcodeproj`, scegliere il proprio team e firmare localmente; microfono/Keychain possono richiedere una firma stabile. Signing, notarizzazione, distribuzione, entitlement effettivi e audio fisico non sono stati verificati. Nessun installer o prodotto root aggiunto. Il file di progetto è riproducibile con `python3 Apps/ZenVoice/Scripts/generate_project.py` (scrive solo nella directory dell'app).

## Setup personale

1. Installare/configurare **separatamente** `zen` e il suo provider nel Terminale. Verificare che un normale avvio nella cartella di progetto funzioni. L'app non effettua setup/provider login per ZenCODE e non ne riscrive la configurazione.
2. Nel setup scegliere **OpenAI API** oppure **ChatGPT Subscription**, il percorso assoluto di `zen` e i progetti consentiti. Solo API richiede la propria chiave; subscription usa il login ChatGPT già configurato in `zen`. Le vecchie impostazioni migrano ad API e non abilitano il nuovo consenso. Se si sceglie una sottocartella Git, viene mostrata e consentita la radice di quel checkout. I symlink sono risolti. Più checkout diversi sono ammessi, inclusi worktree Git separati; non è isolamento sandbox.
3. Accettare il consenso cloud del provider selezionato: API include i costi API; subscription dipende dai limiti del piano/provider, senza promessa di ore o costo zero. La chiave API preesistente resta in Keychain anche passando a subscription; non è letta né inviata dal nuovo bridge.
4. Chiudere il setup e scegliere **Attiva**. Il microfono viene richiesto soltanto su attivazione esplicita; capture API inizia dopo `session.updated`; subscription richiede il microfono durante la negoziazione WebRTC avviata da Attiva. Usare preferibilmente cuffie. Chiedere vocalmente un incarico, specificando il progetto quando ambiguo; chiedere a voce stato o cancellazione.

OpenAI raccomanda chiavi di backend o token effimeri per client distribuiti: questa è una utility **personale sul proprio Mac**, non un'app da distribuire con una chiave condivisa/incorporata. Non esiste alcun backend aggiuntivo. Audio, trascrizioni cloud necessarie ai consensi, prompt, nomi/percorso dei progetti e contenuti dei task possono raggiungere OpenAI. ZenCODE invia separatamente i propri dati al provider configurato.

ZenVoice non scrive audio/trascrizioni/storia dei task su disco, né logga i payload provider/ACP. Conserva soltanto i percorsi e il consenso nei defaults, la chiave in Keychain e buffer limitati in RAM. Questa assenza di storage **non** è una promessa sulla retention di OpenAI, sui crash dump di sistema, o sulla persistenza propria di ZenCODE (`~/.zencode`, task/sessioni/memoria e autorizzazioni già configurate).

## Processi, task e sicurezza

- Un processo `zen --acp --working-directory <checkout>` e una sessione ACP per checkout. Stato mutabile isolato su `MainActor`; reader stdio incrementale POSIX non bloccante con buffer da 16 KiB, attese cancellabili e yield cooperativo, writer usa pipe non bloccanti e `F_SETNOSIGPIPE`.
- `initialize` versione 1, audio false; `session/new`, `session/prompt`, update testuali/tool, `session/request_permission`, `session/cancel` e `session/close`. Framing JSON-RPC newline, non `Content-Length`. `toolCall` completo incluso `_meta.rawInput` è inoltrato come dato non fidato, senza assumere vecchi tool kind.
- Un solo prompt attivo sul medesimo checkout: una nuova richiesta mentre occupato è rifiutata con spiegazione, **non accodata né riprodotta**. Checkout differenti procedono in parallelo. Nessuna promessa di lock interprocesso con altri terminali/istanze di ZenCODE o di isolamento dei file modificabili dai tool.
- Le pipe restano aperte con **Disattiva**: microfono, playback e WebSocket si spengono, i processi/task restano vivi. Le nuove richieste di autorizzazione quando disattivo sono rifiutate; una richiesta pending viene invalidata e rifiutata. Quindi i task possono terminare con operazione negata, non restano bloccati indefinitamente.
- **Esci** chiede conferma se esistono task/avvii attivi, invia cancel/close, poi EOF; fallback terminate e kill dopo grace period. Dopo conferma, lo stato di chiusura è immediato e irreversibile: Attiva, setup e nuovi tool sono bloccati; anche gli avvii ACP sospesi vengono chiusi senza inviare nuovi prompt. Chiusura app dopo il cleanup del bridge voce e il grace period ACP. Non promette sopravvivenza dei task all'uscita né gestione di discendenti daemonizzati autonomamente dai tool.
- Errori di protocollo/EOF invalidano definitivamente quel client e ne chiudono il processo; il checkout non viene automaticamente riavviato in uno stato incerto. Riavviare l'app dopo aver verificato lo stato locale. Timeout initialize 20 s, session/new 30 s, prompt 60 min, close 2 s; timeout writer 5 s. Framing massimo 1 MiB, coda writer 1 MiB, prompt massimo 24 KiB, risultati vocali 16 KiB.
- I figli ereditano soltanto HOME/PATH/TMPDIR/LANG/LC_ALL/USER/SHELL: nessuna chiave voce o variabile provider dell'app. Condividono il setup standard `~/.zencode`. Le autorizzazioni persistenti **già** presenti possono evitare nuove richieste ACP; l'app non le modifica.

### Conferme vocali API deny-by-default

Nessun tool Realtime seleziona permessi. Un'unica richiesta pending alla volta riceve una frase casuale di sei parole, legata all'ID JSON-RPC e all'istanza del processo. Richieste simultanee ulteriori sono rifiutate in sicurezza. L'assistente deve annunciare richiesta e frase; la trascrizione **dell'output** deve contenere la frase e la risposta correlata tramite response/item deve risultare completata. Questo certifica solo la generazione, non il playback.

Solo dopo callback `.dataPlayedBack` di tutti i buffer dell’item correlato (non semplice coda svuotata) e almeno un secondo di quiete si registra un watermark dei campioni microfono inviati. Un nuovo `speech_started` deve avere `audio_start_ms` successivo al watermark. Solo `conversation.item.input_audio_transcription.completed` per quell'item, non delta/modello/tool/output precedente, può confrontarsi con la frase esatta normalizzata (minuscole, spazi/punteggiatura). Scadenza 90 s, solo `allow_once`, mai `allow_always`. Dire esattamente **rifiuto** in un turno valido nega il permesso. Voce disattivata/disconnessa o scadenza cancellano la challenge. Un’interruzione prima del completamento del playback rifiuta subito la richiesta; se la frase non viene pronunciata fedelmente, la challenge non si abilita e scade. Nessuna approvazione implicita.

È una verifica di contenuto e temporalità, **non** riconoscimento biometrico né protezione da un'altra persona o sorgente audio che pronunci deliberatamente la frase dopo la finestra di quiete. Non usare per operazioni che richiedano autenticazione forte. Output ZenCODE e metadati tool restano non fidati: possono essere descritti, non diventano policy locale o consensi.

## Realtime GA (provider API) e limiti

`wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1`, Authorization Bearer personale, nessun beta header. `session.type=realtime`, `output_modalities=[audio]`, `audio.input/output.format={type:audio/pcm,rate:24000}`, server VAD automatico, trascrizione cloud `gpt-4o-mini-transcribe`. Nessun modello locale: AVFoundation converte e riproduce soltanto audio.

L'implementazione binaria usa **PCM signed 16-bit little-endian mono a 24 kHz**. La reference GA consultata conferma `audio/pcm`/24000 ma l'estrazione web disponibile non ha esposto esplicitamente profondità/endianness/canali; il controllo documentale binario resta un caveat da chiudere, non una compatibilità certificata tramite test live.

Output audio gestito da `response.output_audio.delta`; barge-in invalida la risposta corrente, scarta i suoi delta tardivi anche prima del primo buffer, invia `response.cancel`, ferma immediatamente il player e manda `conversation.item.truncate` con item/content_index 0. `audio_end_ms` include solo buffer con callback `.dataPlayedBack`: confine conservativo realmente riprodotto, **esclude la porzione del chunk ancora in riproduzione** e non conta audio solo ricevuto/renderizzato. La barriera correla le creazioni locali tramite `response.metadata.zenvoice_request_id`: una creazione pending interrotta resta negata anche se `response.created` arriva tardi, senza sostituire la nuova risposta VAD. Il cancel è mirato al `response_id` noto; soltanto l'errore benigno `response_cancel_not_active` correlato a un nostro cancel è ignorato. Un `response.done` vecchio non conclude una risposta nuova; lo stato si azzera al cambio sessione. Limite playback 30 s, capture stream 12 chunk, send stream 64 eventi; overflow disattiva, non perde arbitrariamente dati continuando la sessione.

Function calls solo da risposte/item `completed`, argomenti completi, dedup `call_id` (massimo 512/sessione), output stringa. Una coda locale evita `response.create` mentre una risposta nota è attiva o il playback precedente non è drenato: i follow-up applicativi ripartono dalla callback `.dataPlayedBack`, una sola volta. Il barge-in invalida sia il follow-up accodato sia quello di un tool ancora in attesa, senza interrompere il task ACP. VAD remoto può comunque correre con il client e un errore server non benigno disattiva in sicurezza, senza replay. Il client non tenta resume/reconnect trasparente. Timeout handshake 20 s e spegnimento prima del limite di 60 minuti. Una riattivazione può riferire i task ancora presenti, non ripete azioni.

### Riferimenti verificati

- [Modello attuale GPT-Realtime-2.1](https://developers.openai.com/api/docs/models/gpt-realtime-2.1)
- [Realtime GA e WebSocket](https://developers.openai.com/api/docs/guides/realtime-websocket)
- [Client events: session.update, input append, truncate, function output, response.create](https://developers.openai.com/api/reference/resources/realtime/client-events)
- [Configurazione GA audio](https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create)
- Contratto locale: `Sources/ZenCODECore/ZenCODE/ACP/{Lifecycle,Permissions,Updates,Routing,Protocol}` e `Docs/architecture.md`.

## Collaudo manuale ancora necessario

La validazione offline e la review mirata di lifecycle, permessi e ordinamento audio sono concluse. Restano da provare una build firmata sul Mac, configurazione/Portachiavi, permesso microfono, conversazione con OpenAI, speaker/cuffie e interruzioni fisiche. Nella verifica offline dell'app e del percorso API non sono state usate chiavi API reali né avviate conversazioni provider; le prove SIWC antecedenti sono distinte e descritte sotto. Il collaudo audio interattivo e la notarizzazione restano da verificare. I test offline coprono framing/limiti, JSON, canonicalizzazione checkout, schema GA, challenge vecchia/eco/temporalità, ordinamento playback/risposte, shutdown e handshake/prompt/permission fake ACP: non sostituiscono un collaudo audio end-to-end.

## ChatGPT Subscription: architettura e differenze di sicurezza

La selezione subscription usa **WebRTC per media** nel WebKit di sistema dell'app e un processo separato **`zen --voice-bridge` per auth/HTTP/WebSocket SwiftNIO**. Non è Codex/app-server, non è ACP e non avvia task. L'app non importa il package root: il `zen` scelto deve essere aggiornato e compatibile con il sistema operativo. Il login viene letto dal normale store di `zen` con snapshot/lock; **nessun refresh automatico**, rotazione token, API fallback o lettura cookie dell'app ufficiale. Se il token è scaduto, rinnovare il login da Terminale e riattivare manualmente.

La pagina WebKit è locale/non-persistente, con CSP e navigazione vincolate. Riceve solo SDP tramite argomenti JavaScript, **mai bearer/refresh token/account ID**. Microfono solo dopo **Attiva** e permesso macOS; video negato. Disattiva applica immediatamente mute nativo, ferma tracce/peer e chiude il bridge. Nessun STUN/TURN arbitrario configurato; i candidati remoti devono essere IP pubblici validi. L'offerta può inviare al provider candidati locali/mDNS; ICE/DTLS/RTP usano la rete reale. Il playback passa da un elemento audio WebKit, non da un TTS locale. Barge-in e cancellazione del media sono gestiti dal protocollo WebRTC/provider: **non** fabbrichiamo item ID, timestamp o receipts di playback equivalenti all'API.

Valori V3: `gpt-live-1-codex`, voce **`cove`**, `openai-alpha: quicksilver=v2`; creazione subscription SIWC e join `/v1/live/<ID>`. Il sideband è controllo: **non invia `input_audio.append`**. `session.context.append`/`delegation.context.append` sono allowlisted; nessun evento sconosciuto viene eseguito. `delegation.created` deve contenere JSON stretto `{action,project,prompt}` per un progetto già consentito; dedup, canonicalizzazione checkout e concorrenza restano identici all'API. Testi non conformi vengono rifiutati, non reinterpretati liberamente. I task vengono eseguiti soltanto dai processi ACP dell'app già esistenti.

### Permessi subscription: conferma esplicita dal menu

Le conferme vocali API restano invariate. Per subscription **la voce e l'output del modello non possono concedere permessi**: aprire il menu, scegliere **Consenti una volta** e leggere la richiesta completa nella modale scorrevole, oppure **Rifiuta**. La richiesta è legata all'istanza client ACP, ID JSON-RPC e attivazione voce. Scade in 90 secondi; `allow_always` non è supportato. Dopo la modale il fence viene ricontrollato: disconnect, Disattiva, Esci o timeout invalidano anche un click tardivo. Nessuna nuova autorizzazione persistente.

Bridge e app scambiano soltanto dati voce necessari su pipe RAM, non log. Limite frame 128 KiB, SDP 64 KiB, testo IPC 16.000 byte (app tronca su confini UTF-8), writer bounded. Close/EOF/cancel eseguono `session.close`, hangup ufficiale best-effort e shutdown NIO; in caso risposta persa non è garantita la chiusura remota. L'app resta in stato di chiusura finché il processo voce esce o scade il grace period; i task ACP possono continuare con Disattiva. Nessuna promessa di quote 12h o parità con Voice Chat/Work ufficiale.

### Collaudo interattivo della nuova integrazione

1. Compilare **anche zen attuale** (`swift build --product zen`) e selezionare quel binario nel setup, non una vecchia installazione senza `--voice-bridge`.
2. Firmare il bundle con identità locale stabile per TCC/Keychain; selezionare subscription, progetti e consenso dedicato. Nessun test automatico attiva il microfono.
3. L'utente sceglie **Attiva**, autorizza il microfono e verifica voce in ingresso/uscita, interruzione e Disattiva con cuffie. Prima di affidare operazioni reali verificare un task innocuo sul checkout consentito e un permesso **Rifiuta** dal menu.
4. Verificare che le attività ACP continuino durante Disattiva, che una richiesta pending venga negata e che Esci chiuda i processi. Riattivare non deve ripetere task.

Le prove diagnostiche antecedenti hanno verificato SIWC 201/WS101/hangup200 ma **non l'audio end-to-end di questa app**. La regressione root del primo frame coalesciato con HTTP101 ora usa `.forwardBytes` ed è coperta da test locale. Il collaudo interattivo del prodotto resta distinto da build/test e handshake.
