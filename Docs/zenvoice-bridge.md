# Separazione tra ZenVoice e ZenCODE

Il precedente protocollo privato `zen --voice-bridge` è stato rimosso. Questo documento resta come riferimento per i collegamenti esistenti: non descrive più un comando utilizzabile.

## Responsabilità

- **ZenVoice** possiede la connessione vocale ChatGPT Subscription: login letto in sola lettura, negoziazione HTTP, controllo WebSocket, istruzioni dell'assistente, deleghe, risultati e chiusura. WebRTC nativo tramite `stasel/WebRTC 155.0.0` gestisce i media nell'app, senza WebKit e senza ricevere credenziali.
- **ZenCODE** mantiene la propria autenticazione generica, il runtime dei progetti e l'interfaccia ACP. Non contiene un avvio, un servizio o un protocollo dedicato a ZenVoice.
- **Desktop Tools** è un componente riutilizzato direttamente dall'app attraverso il proprio eseguibile di feature. Le azioni Desktop non richiedono un agente o una sessione ZenCODE.
- Il riuso unidirezionale di librerie o componenti generici è compatibile con questi confini; le istruzioni e il ciclo di vita specifici dell'assistente vocale non appartengono al runtime ZenCODE.

L'app può leggere il login e gli indici dei progetti già presenti nella configurazione ZenCODE senza richiedere registrazione delle TUI o modifiche ai loro processi. Per gli incarichi sui progetti continua a usare la normale interfaccia ACP. Questa integrazione non implica controllo delle sessioni Terminale già aperte.

## Sicurezza e limiti

Le credenziali Subscription restano in memoria nel trasporto nativo dell'app; nessun refresh automatico, fallback a fatturazione API, invio al componente media o passaggio nell'ambiente dei processi Desktop. La connessione ha host fissi, redirect negati, limiti su messaggi e timeout, con chiusura remota best-effort.

Desktop è opt-in, con conferma nativa per ogni operazione, scadenza e invalidazione alla disattivazione. Si riusa l'installazione locale esistente, senza installarla o compilarla automaticamente. Gli screenshot non sono abilitati: il contratto per le immagini nel canale Subscription non è verificato.

I test offline dell'app includono un controllo sui sorgenti runtime/CLI che segnala la reintroduzione del bridge dedicato. Non sostituiscono la prova audio interattiva, i consensi macOS o una verifica end-to-end con il provider.

Per architettura corrente, configurazione e collaudo vedere [Apps/ZenVoice/README.md](../Apps/ZenVoice/README.md).
