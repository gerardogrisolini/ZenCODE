# Valutazione Core AI e piano di integrazione del backend

**Stato:** proposta tecnica; nessun backend è implementato da questo documento.
**Ricerca consultata:** 3 agosto 2026.
**Decisione:** **GO allo spike tecnico; NO-GO alla produzione fino al superamento dei gate di questo documento.**

## Decisione in una frase

**Core AI è un runtime beta per modelli e asset portati dall'app, disponibile da OS 27, non un accesso implicito a un modello Apple.** È quindi una base ragionevole da verificare con uno spike controllato per un LLM on-device posseduto e distribuito da ZenCODE, ma non è oggi un motivo sufficiente per approvare un backend di produzione.

La distinzione è intenzionalmente netta:

| Decisione | Esito | Motivo |
| --- | --- | --- |
| **GO allo spike** | Sì, limitato a macOS 27+ e a un asset scelto, con Xcode/SDK 27 | Il probe locale ha importato e compilato `CoreAI`; Apple documenta il lifecycle di asset, specializzazione e inferenza. |
| **GO alla produzione** | **No, non ancora** | Framework beta, conversione e runtime autoregressivo ancora da dimostrare, costo degli asset e compatibilità hardware/performance da misurare. |
| **Fallback operativo** | I backend remoti rimangono il default e invariati | Non deve esistere una conversione implicita da locale a remoto, né il contrario. |

Questo documento usa i risultati di `coreai-architecture-audit`,
`coreai-framework-research` e `coreai-sdk-probe`; le fonti Apple e i
riferimenti al checkout sono riportati per rendere verificabili le decisioni.

## Fatti, ipotesi e limiti

### Fatti confermati

- Core AI è contrassegnato da Apple come **Beta Software**. Il framework prepara,
  distribuisce ed esegue sull'apparecchio modelli neurali forniti dall'app in
  formato `.aimodel`, usando CPU, GPU e Neural Engine quando appropriato [A1].
- Le API Core AI osservate nel probe sono disponibili da **macOS 27.0**; il
  contro-probe con deployment macOS 26 ha fallito per availability. Il probe ha
  compilato invece un programma temporaneo con Xcode 27, SDK macOS 27 e Swift
  6.4. Questo è un dato della toolchain usata, non una promessa di compatibilità
  retroattiva.
- `AIModelAsset` ispeziona un bundle `.aimodel` senza specializzarlo;
  `AIModel` rappresenta il modello specializzato per dispositivo; una
  `InferenceFunction` possiede pesi e buffer intermedi; `ComputeStream` può
  serializzare il lavoro in base alle dipendenze dei valori letti e scritti
  [A2][A3][A4][A5].
- La specializzazione può essere costosa, è memorizzata in cache e dipende da
  dispositivo, opzioni e versione OS. Apple prevede anche la compilazione
  ahead-of-time in asset `.aimodelc` per architettura, che riduce ma non elimina
  il lavoro on-device [A6][A7].
- Il repository corrente è deliberatamente **remote-only**:
  `Docs/architecture.md:60-73` dichiara che non ospita pesi né inferenza
  in-process. Il commit `8cf38fec` (*Removed local inference*, 19 luglio 2026)
  ha rimosso MLX, flag `--mlx` e relativi target. Non esiste un backend locale
  da riaccendere tramite una sola opzione.
- Il punto di estensione esistente è
  `AgentRuntimeBackend` (`Sources/ZenCODECore/ZenCODE/Agent/Runtime/Configuration/AgentRuntimeConfiguration.swift:466-539`)
  e la relativa factory (`:97-100`). `AgentCoreSessionRunner` riceve già una
  `backendFactory` e conserva l'orchestratore di sessione
  (`Sources/ZenCODECore/ZenCODE/Agent/Core/Coordinator/AgentCoreSessionRunner.swift:55-71`).
- `AgentCoreBackend` idrata un backend con orchestratore, executor dei
  sotto-agent, provider degli strumenti e sessioni **prima** di pubblicarlo
  (`Sources/ZenCODECore/ZenCODE/Agent/Core/Coordinator/AgentCoreBackend.swift:347-410`).
  Il backend locale deve conservare quest'ordine.

### Ipotesi progettuali da validare

- Un LLM scelto, i suoi operatori e il suo schema prefill/decode sono
  esportabili in Core AI con accuratezza e consumo di memoria accettabili.
- Il tokenizer, il template chat e il parser dei tool del modello selezionato
  possono essere integrati senza introdurre un nuovo formato di conversazione o
  aggirare l'autorizzazione degli strumenti esistente.
- La cancellazione cooperativa del loop token-per-token, combinata con il
  fencing già presente nel runner, è sufficiente anche se non si può annullare
  il lavoro Core AI già codificato sul dispositivo. Non è stata trovata una
  garanzia Apple di cancellazione di `ComputeStream`; va misurata, non assunta.
- Una distribuzione verificata degli asset, con licenze e dimensioni compatibili
  con il prodotto, è disponibile. Questa è una decisione di prodotto e legale,
  non una capacità fornita dal framework.

### Cosa Core AI non fornisce automaticamente

Core AI non fornisce un modello linguistico Apple né un endpoint LLM. Non
fornisce neppure, in quanto tali, tokenizer, chat template, campionamento,
semantica della KV cache, streaming testuale o tool calling. La funzione di
inferenza opera su tensori e stati che l'app definisce nel modello.

| Responsabilità dell'app o di una libreria scelta | Supporto Core AI documentato |
| --- | --- |
| scelta, licenza, provenienza, pesi, metadati e distribuzione del modello | asset `.aimodel`/`.aimodelc`, ispezione e caricamento |
| export del grafo, nomi e shape di input/output, prefill e decode | `InferenceFunction` su input, stati e output dichiarati |
| tokenizer, token speciali, chat template e conteggio token | nessun tokenizer/chat protocol implicito |
| greedy/sampling, temperatura, top-k/top-p, seed, stop sequence | loop autoregressivo dell'app sopra l'inferenza |
| allocazione, aggiornamento e troncamento della KV cache | stati in/out del modello; la semantica della cache resta dell'app |
| conversione token → UTF-8, buffering e streaming verso la TUI | callback `onEvent` del contratto ZenCODE, non streaming LLM nativo |
| grammatica/JSON dei tool, parser, autorizzazione, esecuzione e tool loop | `AgentToolProvider`, autorizzatore e orchestratore ZenCODE già esistenti |
| safety, valutazione, osservabilità e fallback esplicito | controlli e policy dell'app |

Il package Apple `coreai-models` è un'indicazione utile, ma non una dipendenza
proposta da questo piano: espone utilities Swift aggiuntive per modelli e
risorse, e conferma che tokenizer e runtime linguistico sono uno strato separato
[A10]. Qualsiasi adozione richiede una verifica separata di API, stabilità,
licenze e dipendenze.

### Distinzione da Foundation Models e Core ML

- **Core AI:** runtime tensoriale per asset dell'app; è il candidato di questa
  valutazione.
- **Foundation Models / `SystemLanguageModel`:** il secondo è l'API che Apple
  documenta per il modello di testo on-device di Apple Intelligence. La sua
  disponibilità dipende da dispositivo e regione [A8]. L'esistenza di Core AI
  **non** conferisce alcun accesso a `SystemLanguageModel`, ai suoi pesi o alla
  sua disponibilità.
- **Core ML:** resta il framework Apple generico per modelli ML; la stessa
  documentazione Core AI rimanda a Core ML per tipi come decision tree e feature
  engineering tabellare [A1][A9]. Non si deve sostituire automaticamente uno
  con l'altro.

## Vincoli del repository da preservare

L'integrazione non deve cambiare il significato di un turno, di una sessione o
di un task graph. I confini rilevanti sono:

1. `Sources/zen/CLI/ZenCODEMain.swift:12-68` rimane il composition root del
   processo: valida, esegue setup e passa il controllo al runner CLI. La
   selezione di un backend Core AI deve avvenire qui o nello strato di
   composizione immediatamente sottostante, non nella TUI e non nel grafo task.
2. `AgentCoreSessionRunner` possiede ciclo di vita, snapshot, restore,
   autorizzazioni, generazioni/fencing e un singolo `SessionTaskOrchestrator`.
   Prima registra la sessione e il task graph, poi crea il backend
   (`AgentCoreSessionRunner.swift:87-114`); la preparazione è single-flight e
   fenced contro reset/shutdown (`:749-850`). Queste responsabilità non migrano
   nel runtime Core AI.
3. `AgentCoreBackend` resta il facade che risolve e idrata il
   `AgentRuntimeBackend`. La factory custom è già preferita al factory remoto
   predefinito (`AgentCoreBackend.swift:347-381`).
4. `AgentRemoteBackendFactory` e i client remoti rimangono immutati e
   utilizzabili su tutte le piattaforme
   (`Sources/ZenCODECore/ZenCODE/Agent/Core/Factory/AgentRemoteBackendFactory.swift:14-144`).
   Una selezione locale non usa chiavi remote e un errore locale non effettua
   fallback di rete silenzioso.
5. Il contratto `AgentRuntimeBackend` conserva creazione/aggiornamento/chiusura
   sessione, `sendPrompt`, `snapshotSession`, preload, compaction, provider
   tool, orchestratore e shutdown. I tipi degli eventi e delle metriche già
   visualizzati da `TerminalChat+Generation` sono l'unica superficie per la
   TUI; non va introdotto un canale Core AI parallelo.
6. Il salvataggio di sessione conserva history, configurazione, transcript e
   `SessionCheckpointTree`; il backend può ricostruire stato transitorio ma non
   eliminare né sostituire il graph (`Docs/architecture.md:58`). Una KV cache o
   un bookmark Core AI non diventa parte dello schema di snapshot senza una
   migrazione esplicita e retrocompatibile.
7. `Package.swift` dichiara oggi Swift tools 6.3, target comuni e macOS 26, ma
   il progetto continua a validare Linux. Core AI non deve essere importato,
   linkato o risolto dalla build Linux.

## Architettura proposta

I nomi seguenti sono **nomi di progetto**, non API già presenti. Lo scopo è
riusare la factory e il protocollo esistenti, non creare una seconda pipeline
agente.

```text
zen / setup / configurazione persistita
        │
        ├── selezione remota (default) ──> AgentRemoteBackendFactory ──> client remoto
        │
        └── selezione Core AI esplicita, macOS 27+ ──> factory Core AI proposta
                                                       │
AgentCoreSessionRunner ─> AgentCoreBackend ─> any AgentRuntimeBackend
        │                                             │
        │                                     CoreAIBackend (actor, proposto)
        │                                             ├─ AssetStore + manifest
        │                                             ├─ CoreAIModelLoader
        │                                             ├─ LLM loop: template/tokenizer/KV/sampler
        │                                             └─ bridge eventi/tool/metriche
        ├─ SessionTaskOrchestrator (unico proprietario mutabile)
        ├─ restore/snapshot/history/fencing
        └─ autorizzazione e AgentToolProvider
```

### Isolamento di piattaforma e packaging

1. Creare un modulo/target interno candidato, ad esempio `CoreAIBackend`, che
   dipende da `ZenCODECore` e importa `CoreAI` soltanto in sorgenti compilate
   per macOS con SDK 27 e sotto guardie `#if canImport(CoreAI)` e
   `@available(macOS 27.0, *)`. Il nome e la meccanica SwiftPM esatta sono un
   deliverable dello spike, non una modifica prescritta qui.
2. Il target comune `ZenCODECore` mantiene solo i contratti neutrali
   (`AgentRuntimeBackend`, configurazione, messaggi, eventi e factory); non
   deve esporre tipi `AIModel`, `NDArray`, `ComputeStream` né linker settings
   Core AI.
3. Il manifest/CI deve rendere il legame Core AI macOS-only. Il gate concreto è:
   una build Linux del prodotto attuale non risolve né compila un import
   `CoreAI`; una build macOS 26 non chiama API 27 e presenta solo backend
   remoto/supporto non disponibile; una build macOS 27 seleziona il modulo
   solo se l'operatore lo richiede.
4. Gli asset del modello non entrano in `Package.resolved`, nei target Linux o
   nelle snapshot di sessione. Per lo spike vivono fuori dal checkout o in un
   fixture autorizzato e minuscolo; per produzione sono bundle o download
   gestiti da un manifesto versionato con checksum, licenza, dimensione,
   modello/tokenizer/template e compatibilità OS/architettura.

Questa separazione preserva sia l'attuale graph Linux sia i backend remoti. Se
la toolchain non permette un confine di target senza trascinare Core AI nella
compilazione Linux, la scelta corretta è bloccare l'integrazione e progettare un
companion macOS separato; non è accettabile indebolire la CI Linux.

### Backend locale e ciclo della sessione

Il candidato `CoreAIBackend` è un `actor` conforme a `AgentRuntimeBackend`.
Mantiene stato transitorio per `sessionID`: riferimento al modello/funzione,
serializzazione per la sessione, KV cache del turno, buffer del parser dei tool
e configurazione del modello. Non possiede il task graph né la persistenza
applicativa.

All'hydration deve accettare, nello stesso ordine osservato in
`AgentCoreBackend.installResolvedBackend`, `installTaskOrchestrator`, executor
borrowed, `updateToolProviders` e sessioni seed. Solo dopo può servire
`sendPrompt`. In particolare:

- `createSession`/`updateSessionOptions` ricostruiscono il prompt dal system
  prompt e dalla history provider-agnostica ricevuti dal runner mediante il
  template del modello. La cache KV è un'ottimizzazione ricostruibile, mai la
  fonte di verità.
- `snapshotSession` restituisce il formato `AgentRuntimeSessionSnapshot` già
  consumato dal runner. Alla riapertura, il backend riprefill dalla history
  salvata e non serializza buffer Core AI come se fossero portabili.
- `compactSession` delega la semantica esistente o dichiara esplicitamente il
  limite finché non è provata una compaction locale; non inventa un conteggio
  token del provider.
- `preloadModel` valida manifest e asset, verifica la funzione attesa e
  specializza/carica il modello in un momento osservabile. Emissioni di
  `.status`, `.diagnostic` e `.modelLoaded` informano l'interfaccia senza
  cambiare il protocollo.
- `sendPrompt` esegue prefill e decode uno token alla volta, pubblica
  `.content` solo dopo decoding UTF-8 valido, accumula la risposta e restituisce
  il normale `DirectAgentResponse`. Token prompt/completion, durata, cache e
  throughput sono conteggiati dal runtime applicativo e mappati nel tipo di
  metriche corrente, non in un evento Core AI nuovo.
- Un tool call resta testo/JSON prodotto dal modello e validato dal parser
  scelto. Il backend deve usare i `AgentToolProvider` installati, le
  autorizzazioni del runner e la sequenza di eventi esistente; non può eseguire
  un comando arbitrario né duplicare un tool call dopo reset o retry.

### Concorrenza e cancellazione

`InferenceFunction` è `Sendable` e Apple dichiara che può allocare buffer
intermedi aggiuntivi per inferenze concorrenti [A4]. Questa proprietà non è una
politica di capacità per ZenCODE. Il backend deve pertanto:

- serializzare i turni della **stessa** sessione e il mutamento della sua KV
  cache; usare uno stream o dipendenze coerenti per quello stato;
- limitare esplicitamente il numero di sessioni/modelli in esecuzione in base
  alla memoria misurata; non dedurre che `Sendable` significhi memoria illimitata;
- verificare cancellazione tra prefill, decode, tool round e attesa dello
  stream; smettere di emettere eventi dopo cancellazione/reset e lasciare che il
  fencing del runner scarti lavoro tardivo;
- misurare separatamente il tempo per fermare il loop applicativo e il tempo
  fino al completamento del lavoro già accodato. Fino a una prova SDK, non
  promettere che una `Task` cancellation annulli l'inferenza Core AI.

## Pipeline del modello e degli asset

La pipeline proposta è separata dal runtime Swift e riproducibile fuori dal
checkout principale:

1. **Scelta del modello.** Registrare origine, revisione immutabile, licenza,
   pesi, lingua, contesto, capacità tool/JSON, limiti di ridistribuzione e
   hardware minimo. Senza permesso esplicito di distribuire pesi e tokenizer,
   il lavoro non supera la fase zero.
2. **Contratto LLM.** Fissare in un manifesto i nomi delle funzioni, input,
   output e stati: almeno prefill/decode o un equivalente verificabile, shape,
   precisione, massimo contesto, tokenizer, special token, chat template e
   versione del parser tool. Il manifesto consente di rifiutare un asset
   incompatibile prima di allocare i pesi.
3. **Export e ottimizzazione.** Partire da un modello PyTorch esportabile,
   applicare Core AI PyTorch Extensions per generare `.aimodel` e valutare
   Core AI Optimization per compressione/quantizzazione solo confrontando
   accuratezza e prestazioni. Operatori non supportati, shape dinamiche e
   stabilità numerica sono failure dello spike, non dettagli da aggirare nel
   backend [A1][A10].
4. **Validazione dell'asset.** Controllare checksum e licenza; usare
   `AIModelAsset` per validità, metadati e firme delle funzioni prima di
   specializzare. I descriptor runtime devono coincidere con il manifesto
   previsto [A2][A3].
5. **Specializzazione e cache.** Caricare con `AIModel`, osservare cold/warm
   start e cache. L'OS può invalidare artefatti specializzati dopo un update e
   può liberare spazio: il loader deve rieseguire download/specializzazione
   anziché considerare la cache una persistenza della sessione [A6].
6. **Ahead-of-time opzionale.** Solo se i tempi cold non rispettano l'obiettivo,
   produrre `.aimodelc` con `coreai-build`, una variante per architettura, e
   scaricare la variante corretta. AOT è limitato da Apple ai dispositivi che
   supportano Apple Intelligence e lascia comunque lavoro on-device; non è una
   scorciatoia universale [A7].
7. **Distribuzione e aggiornamento.** Bundle per il primo asset piccolo oppure
   download atomico in directory dell'app, con manifest firmato/checksum,
   spazio libero preflight, rollback dell'asset precedente e invalidazione della
   cache derivata. Il modello, tokenizer e template si aggiornano come un'unità
   compatibile.

## Configurazione, setup e privacy

La selezione deve essere esplicita e persistita come una nuova variante di
backend, con default immutato **remote**. I nomi CLI concreti (per esempio un
futuro selettore `coreai` e un identificatore di asset) sono da definire dopo
lo spike: non vengono introdotti né documentati come opzioni esistenti.

Il setup deve:

- mostrare Core AI solo su macOS 27+ e solo se il modulo/asset è disponibile;
- richiedere conferma esplicita dell'asset locale, dimensione su disco, licenza
  e percorso o catalogo di download;
- validare checksum, funzioni, tokenizer/template e spazio necessario prima di
  rendere attiva la selezione;
- rendere chiaro che Core AI usa asset dell'app e **non** il modello Apple di
  sistema;
- offrire un ritorno esplicito al provider remoto selezionato, senza inviare a
  un provider esterno un prompt che l'utente credeva locale;
- trattare URL, checksum e manifest come configurazione di asset, mai come
  credenziali remote. Le chiavi restano provider-scoped nel percorso remoto.

## Piano incrementale e gate

| Fase | Output senza espandere il perimetro | File/probabili aree coinvolte in un'implementazione futura | Gate misurabile |
| --- | --- | --- | --- |
| 0. Contratto e riproducibilità | modello candidato, licenza, manifest, fixture token e script export fuori dal repo | documentazione di asset; pipeline CI macOS separata | licenza approvata; checksum presente; export ripetibile; nessun peso grande nel repo o in `Package.resolved` |
| 1. Spike Core AI isolato | programma temporaneo macOS 27 che carica un asset, ispeziona descriptor e genera con greedy decode | spazio temporaneo esterno; nessuna modifica a `ZenCODECore` | `AIModelAsset` e descriptor coincidono con manifesto; i primi 32 token ID della fixture coincidono con il riferimento fissato; build Linux del repository resta verde |
| 2. Runtime LLM minimo | tokenizer, chat template, prefill/decode, KV cache e streaming in modulo macOS isolato | nuovo target interno candidato `CoreAIBackend`; test dedicati Core AI | 100 turni deterministici della fixture senza crash; output UTF-8 e stop sequence corretti; memoria peak e token/s registrati su hardware dichiarato |
| 3. Adapter ZenCODE | conformità completa a `AgentRuntimeBackend`, factory di composizione e selezione esplicita | `AgentRuntimeConfiguration`, `AgentCoreBackend`, composition root `zen`, setup e test runner; non `SessionTaskOrchestrator` | test del runner passa con backend fake e Core AI; snapshot/restore di 10 sessioni conserva history e task graph; nessun fallback remoto implicito |
| 4. Tool loop e hardening | parser tool, autorizzazione, cancellazione cooperativa, metriche e limiti di capacità | bridge dei provider tool, test eventi/metriche/sessione | 30 round tool controllati: un'esecuzione per call ID, zero duplicati, autorizzazione negata non esegue il tool; cancellazione non emette contenuto dopo fencing |
| 5. Asset delivery e performance | catalogo/aggiornamento, cache, telemetry e matrice dispositivi | store asset macOS, setup/doctor, job CI macOS 27 | cold/warm load, RAM, primo token, token/s, disco e failure rate soddisfano SLO di prodotto approvati su ogni hardware supportato |
| 6. Decisione produzione | review tecnica, legale e release | documentazione/release/CI; nessun cambio automatico di default | tutti i gate precedenti verdi con OS finale, API beta rivalutate e rollback verificato |

Le fasi 1 e 2 sono lo **spike** approvato. Le fasi 3-6 restano pianificazione;
non sono autorizzazione implicita a introdurre un backend né ad alzare il
deployment target globale a 27.

### Test e matrice di compatibilità

| Ambiente | Build/import | Esecuzione prevista | Assert principali |
| --- | --- | --- | --- |
| macOS 27, Xcode/SDK 27, hardware del catalogo | compila e importa Core AI nel solo modulo isolato | asset fixture, specializzazione cold/warm, prefill/decode | descriptor, token fixture, cache, memoria, metriche, cancellazione |
| macOS 27, ogni architettura che il catalogo dichiara | variante `.aimodel` o `.aimodelc` corretta | test di regressione e benchmark | correttezza, tempi, spazio, fallback esplicito se non supportata |
| macOS 26 | il core comune continua a compilare; nessuna API Core AI invocata | solo percorso remoto o messaggio esplicito di non disponibilità | nessun crash/link Core AI; configurazione locale non selezionabile |
| Linux CI | nessun import/link/risoluzione Core AI | backend remoti, sessioni, tool graph e restore correnti | build/test invariati; il codice condizionale non degrada il graph condiviso |
| fixture fake senza Core AI | tutti i sistemi | `AgentCoreSessionRunner` con `CapturingAgentRuntimeBackend` | factory, hydration, restore, orchestratore e generation fencing; estendere `Tests/ZenCODECoreTests/Agent/AgentCoreSessionRunnerTests.swift` |
| test macOS Core AI | modulo isolato | asset minimo con tool finto | streaming, tool parser, una sola esecuzione, snapshot, metriche e cancellazione |

Per ogni test che richiede asset reale si registrano modello, revisione, hash,
OS, Xcode, chip, memoria, opzioni di specializzazione e risultati. Non devono
entrare in test unitari Linux download di pesi, conversioni Python o misure di
rete.

## Rischi e mitigazioni

| Rischio | Impatto | Mitigazione e condizione di stop |
| --- | --- | --- |
| API Core AI beta cambia prima dell'OS finale | build/ABI/comportamento instabile | pin di Xcode/SDK per CI, smoke build a ogni beta, review prima della release; stop se la migrazione rompe il confine Linux o il contratto runtime |
| macOS 27, Metal Toolchain o hardware non disponibili | impossibile compilare/caricare/specializzare | lane CI macOS 27 dedicata; controllo availability e messaggio esplicito; i remoti restano disponibili |
| export non supporta operatori, stati o shape del LLM | nessun runtime corretto | prototipo con asset piccolo prima dell'adapter; fixture token e descriptor; stop invece di inserire workaround non verificati |
| pesi/tokenizer non ridistribuibili o troppo grandi | rischio legale, installazione e costo disco | approvazione legale, manifest, hash, download atomico, quota e rollback; stop senza licenza e budget disco |
| latenza di specializzazione, RAM o throughput inadeguati | UX e stabilità | misurare cold/warm, limite di concorrenza, unload esplicito, AOT soltanto dopo benchmark; non pubblicare senza SLO per hardware |
| cache specializzata cancellata/invalida dopo OS update | riavvii lenti o asset non trovati | trattare `.aimodel`/download come source of truth, rilevare cache miss, rispecializzare/reinstallare; non salvare cache come snapshot di sessione |
| cancellazione e concorrenza ambigue | CPU/GPU occupata, output tardivi, duplicazioni | actor per sessione, limite globale, controlli cooperativi e generation fence; gate di test sui late event |
| tool call malformato o ripetuto | esecuzione indesiderata | parser versionato, validazione JSON/schema, provider/authorization esistenti, idempotenza per call ID e test negativo |
| divergenza tra locale e remoto | history, formati o metriche incompatibili | riuso esclusivo di `AgentRuntimeBackend`, `DirectAgentEvent`, snapshot e tool providers; test di parità con backend fake |
| manutenzione del modello e delle dipendenze | debito e regressioni numeriche | catalogo ristretto, lock di revisione, benchmark per release, ownership e processo di ritiro asset |

## Fonti e riferimenti verificabili

### Fonti Apple

Tutte le pagine seguenti sono state consultate il **3 agosto 2026** e riportano
informazioni preliminari/beta dove indicato.

- **[A1] Core AI — overview:** https://developer.apple.com/documentation/coreai
- **[A2] Integrare modelli on-device con Core AI:** https://developer.apple.com/documentation/coreai/integrating-on-device-ai-models-in-your-app-with-core-ai
- **[A3] `AIModel` e lifecycle di specializzazione/caricamento:** https://developer.apple.com/documentation/coreai/aimodel
- **[A4] `InferenceFunction`, stati e concorrenza:** https://developer.apple.com/documentation/coreai/inferencefunction
- **[A5] `ComputeStream`:** https://developer.apple.com/documentation/coreai/computestream
- **[A6] Gestione di specializzazione e cache:** https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching
- **[A7] Compilazione ahead-of-time e `.aimodelc`:** https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time
- **[A8] Foundation Models / `SystemLanguageModel`:** https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
- **[A9] Core ML — overview:** https://developer.apple.com/documentation/coreml

Fonte Apple complementare, da trattare come codice/esempi da valutare e non
come contratto del progetto:

- **[A10] `apple/coreai-models`:** https://github.com/apple/coreai-models

### Riferimenti del repository

- `Docs/architecture.md:24-45, 58, 60-73` — graph SwiftPM, proprietà del task
  graph e confine provider remoto vigente.
- `Package.swift:1-169` — Swift tools 6.3, target condivisi e piattaforma
  dichiarata macOS 26.
- `Sources/zen/CLI/ZenCODEMain.swift:12-68` — composition root e setup.
- `Sources/ZenCODECore/ZenCODE/Agent/Runtime/Configuration/AgentRuntimeConfiguration.swift:97-100, 466-539` — factory e protocollo runtime.
- `Sources/ZenCODECore/ZenCODE/Agent/Core/Coordinator/AgentCoreSessionRunner.swift:55-71, 87-114, 749-850` — factory, lifecycle e fencing.
- `Sources/ZenCODECore/ZenCODE/Agent/Core/Coordinator/AgentCoreBackend.swift:24-41, 347-410` — risoluzione e hydration.
- `Sources/ZenCODECore/ZenCODE/Agent/Core/Factory/AgentRemoteBackendFactory.swift:14-144` — factory remota da mantenere separata.
- `Tests/ZenCODECoreTests/Agent/AgentCoreSessionRunnerTests.swift` e
  `Tests/ZenCODECoreTests/Runtime/SessionTaskOrchestratorTests.swift` — punti
  di estensione per regressioni di sessione e task graph.
- Git `8cf38fecb6e7a0e603ede1c6a57fa4af0791f8ad` — rimozione intenzionale della
  precedente inferenza locale MLX.

## Conclusione

Il progetto **non** deve descrivere Core AI come «il modello Apple locale» né
come una sostituzione pronta dei backend remoti. È un runtime beta, OS 27+, per
asset che ZenCODE deve scegliere, convertire, distribuire, tokenizzare e
orchestrare.

La decisione è pertanto inequivocabile: **GO allo spike limitato e misurabile**
che prova asset, loop autoregressivo e isolamento di piattaforma; **NO-GO alla
produzione** finché tutti i gate di correttezza, tool safety, restore, Linux,
licenze, memoria, prestazioni e stabilità dell'SDK finale non sono soddisfatti.
