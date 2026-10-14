# ZenVoice (prima versione personale)

App **separata** SwiftUI, solo status bar (`MenuBarExtra`, `LSUIElement`). Nessuna finestra principale o icona Dock: configurazione riapribile dal menu e modale di conferma per i permessi subscription. Nessuna dipendenza da `ZenCODECore` o dal package root. Il media Subscription usa **stasel/WebRTC 155.0.0**, dipendenza binaria SwiftPM esclusiva dell'app. Il progetto include Swift 6 language mode, strict concurrency e `MemberImportVisibility`. Il generatore mantiene il baseline macOS **14.0+**; il progetto Xcode corrente contiene impostazioni manuali (incluso deployment **27.0**) che non vengono sovrascritte dalla migrazione.

## Build e test isolati

Dalla radice del repository, con Xcode selezionato tramite `xcode-select` (ambiente previsto: Xcode 27 / Apple Swift 6.4 / SDK macOS 27):

```sh
xcodebuild -project Apps/ZenVoice/ZenVoice.xcodeproj -scheme ZenVoice \
  -configuration Release -derivedDataPath /tmp/ZenVoice-NativeBuild \
  -clonedSourcePackagesDirPath /tmp/ZenVoice-NativePackages \
  CODE_SIGNING_ALLOWED=NO build > /tmp/ZenVoice-NativeRelease.log 2>&1

xcodebuild -project Apps/ZenVoice/ZenVoice.xcodeproj -scheme ZenVoice \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/ZenVoice-NativeBuild \
  -clonedSourcePackagesDirPath /tmp/ZenVoice-NativePackages \
  CODE_SIGNING_ALLOWED=NO test > /tmp/ZenVoice-NativeDebugTests.log 2>&1

git diff --check -- Apps/ZenVoice CHANGELOG.md
```

**Verifica:** il collaudo audio interattivo della nuova integrazione subscription richiede l'utente (nessuna attivazione automatica). Il test target è **unhosted**: compila i componenti di protocollo/media ma non avvia `ZenVoice.app` e non include `@main`, `AudioIO` o `VoiceModel`. I test nativi in `NativeWebRTCMediaTests.swift` iniettano un driver e un signaling interamente in memoria: non inizializzano `RTCPeerConnectionFactory`, non creano peer reali e non aprono capture, playback o rete. Coprono startup, readiness a tre condizioni, cancellazione, callback di epoch estranei/tardivi, scadenze offer/answer/readiness/shutdown e stop durante apertura HTTP simulata. Restano i test preesistenti di protocollo, consensi, Desktop e shell ACP fake. Nessun provider, API key, Keychain, microfono o rete nei test. Download e risoluzione SwiftPM richiedono invece rete pubblica.

Il bundle non firmato serve solo al controllo di compilazione. Per uso personale aprire `ZenVoice.xcodeproj`, scegliere il proprio team e firmare localmente; microfono/Keychain possono richiedere una firma stabile. Signing, notarizzazione, distribuzione, entitlement effettivi e audio fisico della migrazione nativa richiedono collaudo separato. Nessun installer o prodotto root aggiunto. `Scripts/generate_project.py` genera il **baseline** standalone, ora con package esatto e nuovi file: **non eseguirlo sopra il progetto personalizzato**, perché non conserva deployment/signing/capability manuali. La migrazione applica una patch mirata al `.pbxproj`, senza eseguire il generatore.

## Setup personale

1. Installare/configurare **separatamente** `zen` e il suo provider nel Terminale. Verificare che un normale avvio nella cartella di progetto funzioni. L'app non effettua setup/provider login per ZenCODE e non ne riscrive la configurazione.
2. ZenVoice legge la connessione selezionata e il login da `~/.zencode/settings.json`, senza modificarli. Nel setup si scelgono i progetti consentiti e, facoltativamente, Desktop per ChatGPT Subscription. Il percorso `zen` per i soli incarichi ACP è `/usr/local/bin/zen`; non è richiesto per aprire la connessione vocale. Se si sceglie una sottocartella Git, viene consentita la radice di quel checkout. I symlink sono risolti; non è una sandbox.
3. Accettare il consenso cloud del provider selezionato: API include i costi API; subscription dipende dai limiti del piano/provider, senza promessa di ore o costo zero. L'app conserva il login solo in memoria per la connessione nativa: niente refresh automatico, scrittura credenziali, cookie dell'app ufficiale o fallback API.
4. Chiudere il setup e scegliere **Attiva**. Il microfono viene richiesto soltanto su attivazione esplicita; capture API inizia dopo `session.updated`; subscription richiede il microfono durante la negoziazione WebRTC avviata da Attiva. Usare preferibilmente cuffie. Chiedere vocalmente un incarico, specificando il progetto quando ambiguo; chiedere a voce stato o cancellazione.

OpenAI raccomanda chiavi di backend o token effimeri per client distribuiti: questa è una utility **personale sul proprio Mac**, non un'app da distribuire con una chiave condivisa/incorporata. Non esiste alcun backend aggiuntivo. Audio, trascrizioni cloud necessarie ai consensi, prompt, nomi/percorso dei progetti e contenuti dei task possono raggiungere OpenAI. ZenCODE invia separatamente i propri dati al provider configurato.

ZenVoice non scrive audio/trascrizioni/storia dei task su disco, né logga i payload provider/ACP. Conserva soltanto percorsi dei progetti e opt-in Desktop nei defaults; credenziali e buffer sono in RAM. Il processo Desktop riceve un ambiente esplicito senza token e uno storage separato in `~/Library/Application Support/ZenVoice`. Questa assenza di storage delle conversazioni **non** è una promessa sulla retention del provider, sui crash dump o sulla persistenza propria di ZenCODE.

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

La verifica offline **antecedente alla sostituzione media nativa**, del 14 ottobre 2026, comprende **build Xcode dell'app riuscita, 84 casi di test dell'app superati, build SwiftPM di `zen` riuscita e 7 test mirati del core superati**. La review ha individuato e portato alla correzione dell'interlock Desktop/ACP e dei limiti end-to-end di testo, risultati e durata dei movimenti. Il test architetturale controlla l'assenza dei simboli e del comando del bridge nei sorgenti runtime/CLI. Le modifiche preesistenti della working tree sono state preservate.

La migrazione a **stasel/WebRTC 155.0.0** è stata verificata con build Release dell'app (anche universale **arm64/x86_64**) e **75 test offline in 10 suite**, inclusi 18 test nuovi senza dispositivi o rete provider. La review ha portato alla correzione della readiness Unified Plan: un receiver esistente non basta, serve anche una direzione negoziata che consenta ricezione audio. Verificati framework incorporato, assenza di link WebKit e conservazione delle impostazioni Xcode preesistenti. Queste verifiche non certificano audio o connessione Subscription dal vivo.

Non sono state avviate conversazioni provider, richieste di permessi TCC o azioni Desktop reali: i test di processo usano eseguibili finti in directory temporanee. Restano da provare la build firmata sul Mac, il login selezionato, microfono, speaker/cuffie, interruzioni, deleghe del provider e azioni Desktop autorizzate. Le prove SIWC antecedenti non certificano il trasporto nativo attuale. Il collaudo audio interattivo e la notarizzazione restano separati da build e test offline.

## ChatGPT Subscription: architettura e differenze di sicurezza

La selezione subscription usa **WebRTC nativo per media** (stasel M155, CoreAudio su macOS) e **URLSession nativo dentro ZenVoice per auth/HTTP/WebSocket**. Non avvia `zen`, Codex/app-server o un agente per la voce. Il vecchio comando dedicato è rimosso da ZenCODE: protocollo, istruzioni vocali e lifecycle sono responsabilità esclusiva dell'app. Il login esistente viene letto dalla configurazione soltanto all'attivazione e mantenuto in memoria; **nessun refresh automatico**, rotazione token, API fallback o lettura cookie dell'app ufficiale. Se scaduto, rinnovare il login da Terminale e riattivare manualmente. Sessioni HTTP effimere senza cookie/cache/credential store, redirect negati e host provider fissi.

`NativeWebRTCMedia` riceve esclusivamente SDP e stati media, **mai bearer/refresh token/account ID**. Il driver costruisce la factory soltanto quando inizia l'offerta, dopo **Attiva**, consenso cloud e permesso microfono macOS già controllati da `VoiceModel`. Non esistono pagina, JavaScript o link al vecchio framework web nell'app o nei test. Audio-only Unified Plan, nessun video encoder/decoder, datachannel locale **`oai-events` ordered**; canali remoti aggiuntivi vengono chiusi e fanno terminare la sessione. Il datachannel non è un secondo canale comandi: nessun parsing/log delle sue trascrizioni o payload. Le deleghe continuano a passare esclusivamente da `VoiceBridgeClient` HTTP/WS.

Nessun STUN/TURN arbitrario configurato (`iceServers = []`); l'answer mantiene i limiti 64 KiB/32 candidati e il controllo degli IP remoti pubblici, con rifiuto di video/sezioni media extra. L'offerta può inviare al provider candidati locali; ICE/DTLS/SRTP usano la rete reale. Capture e playback passano dal default ADM macOS **AudioDeviceMac/CoreAudio** della distribuzione, non da API audio iOS o un TTS locale. Gli header M155 macOS non espongono `RTCAudioSession` o un controllo pubblico start/stop dell'ADM. Disattiva invalida subito epoch e operazioni applicative, accoda immediatamente sul worker seriale disable della traccia microfono e delle tracce remote, volume remoto zero, close di datachannel/peer e rilascio factory. **Mute/disable non equivale a fermare l'hardware**: close e rilascio sono il percorso nativo di teardown ADM; non promettiamo una latenza hardware certificata o l'interruzione forzata di una chiamata SDK bloccata. Nessuna attesa di delegate blocca `MainActor`.

Deadline: offerta 8 s (raccolta ICE massimo 2 s), applicazione answer 8 s, readiness 12 s, avvio complessivo 40 s, attesa teardown nativo 2 s e shutdown applicativo massimo 10 s. La scadenza non finge un successo del cleanup: invalida gli eventi, richiede close e lascia terminare il cleanup nativo/HTTP best-effort fuori dall'attesa UI. Readiness richiede **peer connected + datachannel open + traccia audio remota live su transceiver non fermato con direzione negoziata `sendRecv`/`recvOnly`**: non certifica pacchetti audio effettivamente ricevuti, uscita fisica, volume di sistema o cuffie corrette. Callback tardive sono ignorate tramite epoch; lo stato RTC resta su una coda seriale, i delegate consegnano snapshot di valore e non attendono `MainActor`. I log SDK sono disabilitati, senza dump SDP/audio/eventi. Barge-in resta del protocollo WebRTC/provider: **non** fabbrichiamo item ID, timestamp o receipts di playback equivalenti all'API.

Valori mantenuti dal contratto subscription esistente: `gpt-live-1-codex`, voce **`cove`**, `openai-alpha: quicksilver=v2`; creazione SIWC e join `/v1/live/<ID>`. Il canale di controllo **non invia `input_audio.append`**. `delegation.created` deve contenere JSON stretto `{action,project,prompt}` per i progetti consentiti, oppure `{tool:"desktop.run",arguments:{...}}` solo quando Desktop è esplicitamente abilitato e disponibile. Le istruzioni sono costruite nell'app. Testi non conformi, tool sconosciuti, consensi generati dal modello, duplicati e richieste screenshot vengono rifiutati. Solo gli incarichi sui progetti vengono eseguiti dai processi ACP.

### Dipendenza binaria e licenze

- Repository: [`stasel/WebRTC`](https://github.com/stasel/WebRTC/tree/155.0.0), requisito SwiftPM **exactVersion 155.0.0** in app/test, non nel package root. `ZenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` registra la revisione del wrapper **`44f36788497f701bc8c0306de3a1c2511d56019d`**.
- Release: [`WebRTC-M155.xcframework.zip`](https://github.com/stasel/WebRTC/releases/download/155.0.0/WebRTC-M155.xcframework.zip), upstream WebRTC **`5bd86a2f17a35dfc986b87d058f511e45805bd1d`**. Il checksum SHA-256 dichiarato dal manifest SwiftPM e **ricalcolato sull'archivio** è `cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe`. SwiftPM controlla il checksum durante la risoluzione; il lockfile fissa il sorgente del manifest, non sostituisce il suo checksum binario.
- Ispezionati gli header della slice macOS arm64/x86_64 e il binario: presenti `AudioDeviceMac`/`audio_device_mac.cc` e link CoreAudio/AudioUnit. Il percorso upstream default ADM usa `kPlatformDefaultAudio`/`AudioDeviceMac`. Questa è evidenza di supporto nativo, **non** una prova di apertura dispositivi o qualità audio sul Mac dell'utente.
- [Licenza della distribuzione e WebRTC](https://github.com/stasel/WebRTC/blob/155.0.0/LICENSE.md): BSD 3-Clause; upstream include anche [PATENTS](https://webrtc.googlesource.com/src/+/5bd86a2f17a35dfc986b87d058f511e45805bd1d/PATENTS) e componenti terzi con propri avvisi. Per redistribuire un bundle occorre conservare copyright, licenze e notice richiesti, inclusi quelli del binario/terze parti. Questo progetto personale non aggiunge un installer né dichiara completata una verifica legale/notarizzazione/distribuzione.
- La migrazione non cambia login in sola lettura, endpoint HTTP/WS, modello/voce, deleghe o selezione provider. Non aggiunge un fallback API.

### Permessi subscription: conferma esplicita dal menu

Le conferme vocali API restano invariate. Per subscription **la voce e l'output del modello non possono concedere permessi**: aprire il menu, scegliere **Consenti una volta** e leggere la richiesta completa nella modale scorrevole, oppure **Rifiuta**. La richiesta è legata all'istanza client ACP, ID JSON-RPC e attivazione voce. Scade in 90 secondi; `allow_always` non è supportato. Dopo la modale il fence viene ricontrollato: disconnect, Disattiva, Esci o timeout invalidano anche un click tardivo. Nessuna nuova autorizzazione persistente.

Il trasporto nativo limita eventi a 128 KiB, SDP/risposta HTTP a 64 KiB, deleghe a 16.000 byte e risultati vocali a 12.000 byte UTF-8. Disattiva/Esci cancellano apertura e invii, chiudono WebRTC/WebSocket ed effettuano hangup best-effort con timeout; una risposta persa prima del call ID non consente di garantire la chiusura remota. Nessun processo voce esterno o NIO nell'app. I task ACP possono continuare durante Disattiva, mentre Desktop viene annullato senza replay. Nessuna promessa di quote 12h o parità con Voice Chat/Work ufficiale.

### Desktop diretto

- Opt-in disattivato per default, anche migrando vecchie impostazioni. Disponibile per **ChatGPT Subscription** e **macOS 26+** con Desktop Tools installato separatamente.
- Si riusa `~/.zencode/features/desktop-tools/.build/release/desktop-tools-feature` via protocollo `--invoke desktop.run`, non un agente ZenCODE. Nessuna build/installazione automatica, risoluzione da PATH o percorso suggerito dal modello. Manifest, ownership, permessi e contenimento del percorso vengono controllati.
- Le azioni ammesse includono lettura di app/finestre/appunti e input/gestione finestre. **Ogni invocazione**, anche di lettura, richiede conferma una tantum dal menu con payload completo e scadenza 90 secondi. Il consenso macOS è distinto e va concesso manualmente nelle Impostazioni di Sistema.
- Nessuna esecuzione concorrente o retry automatico. Disattiva/Esci interrompono il processo. Una cancellazione non annulla effetti già avvenuti. Per tutta l'operazione Desktop, inclusa attesa e cancellazione, sono rifiutate nuove richieste di permesso ACP: un input sintetico non deve azionare un'altra conferma.
- Testi Desktop fino a 8.000 byte UTF-8 e delega JSON completa fino a 16.000 byte, inclusi escape/spazi. Entro il limite globale dell'evento, una delega troppo lunga viene rifiutata come singola operazione, senza interrompere la conversazione. I risultati Desktop devono rientrare integralmente nei 12.000 byte del contenuto vocale, prefissi inclusi: altrimenti viene restituito un errore esplicito, mai un JSON parziale. Durata movimenti 0–10 secondi, attesa fino a 30.
- **Screenshot e controllo visivo non sono abilitati:** il contratto immagini Subscription non è verificato. Allegati e percorsi PNG non vengono inoltrati come immagini; non si devono indovinare coordinate di controlli. Coordinate/destinazione e focus devono essere confermati dall'utente. Non è un'integrazione strutturata Calendario/Contatti.
- Test offline usano esclusivamente eseguibili finti in directory temporanee, mai il tool installato o il desktop reale.

### Collaudo interattivo della nuova integrazione

1. Compilare e firmare **ZenVoice**. Non occorre ricompilare `zen` per il canale vocale; `zen` serve soltanto per i progetti. Installare Desktop Tools separatamente se si desidera abilitarlo.
2. Firmare il bundle con identità locale stabile per TCC/Keychain; selezionare subscription, progetti e consenso dedicato. Nessun test automatico attiva il microfono.
3. L'utente sceglie **Attiva**, autorizza il microfono e verifica voce in ingresso/uscita, interruzione e Disattiva con cuffie. Prima di affidare operazioni reali verificare un task innocuo sul checkout consentito e un permesso **Rifiuta** dal menu.
4. Verificare che le attività ACP continuino durante Disattiva, che una richiesta pending venga negata e che Esci chiuda i processi. Riattivare non deve ripetere task.

Le prove diagnostiche antecedenti riguardavano il vecchio media/trasporto e non certificano questa migrazione a WebRTC nativo. Build e test offline non sostituiscono il collaudo audio end-to-end, l'effettivo uso dei tool dal modello, i consensi TCC o la verifica di immagini Subscription. Nessuna conversazione provider o azione Desktop reale viene avviata automaticamente per validare il codice.
