# AgentSeatKit, spec di hand-off

Stato: **finale**, 8 settembre 2026. Consolidata dalla mappa wayfinder `map.md` (15 ticket chiusi). Ogni sezione punta alla nota di ricerca che la giustifica in `research/`. Il piano di implementazione è nella sezione 12 e nei ticket di `implementation/`. L'implementazione è per agenti Opus 5 High, una fase per sessione, a partire dal package stub già in posizione.

## 1. Obiettivo e confine

Estrarre da AgentSeatLab (`Research_locator`) tutto ciò che controlla il Mac ed è agnostico rispetto a chi decide: display virtuale, input in background (tastiera, testo, click, drag, scroll), recinto del cursore, cattura del seat, orchestrazione con guard e recupero. Planner, client LLM, osservazione AX e UI restano nel Lab. La migrazione è anche pulizia: entra solo ciò che funziona oggi nel percorso agente; ciò che è FAIL o "da eseguire" va in `docs/spi-ledger.md`, non nel codice.

Invarianti non negoziabili:

- **Il kit riceve coordinate osservate, non alberi.** L'osservazione (schermo, analisi, rappresentazione, modello) sta fuori; ogni punto del mouse arriva con l'identità, la geometria e la scala che lo hanno prodotto. L'unico uso di Accessibility nel kit è la **collocazione** della finestra: `AXPosition` per spostarla, `AXRaise` per portarla on stage, `_AXUIElementGetWindow` per trovarne l'elemento (ticket 16). `TargetReader` **legge e restituisce**: un albero AX ridotto a un array di strutture leggere di valore, mai una scrittura sul bersaglio, mai un'azione, mai un fallback di una facility; nessuna facility dipende da lui, e chi lo chiama decide cosa farne (decisione del 09/09/2026).
- **Nessun fallback cross-seat**: nessun evento globale alla User Seat, mai; su simbolo, layout o build sconosciuti la facility rifiuta (fail closed).
- **Mai replay di un effetto incerto**: un Command con conferma `unknown` non si ripete.
- **Il kit non decide azioni**: verifica dell'effetto, chiusura di finestre, scheduling fra agenti sono del chiamante.

## 2. Nome, posizione, toolchain

- Package `AgentSeatKit` in `/Users/mac/Forte_Projects/AgentSeatKit/` (stub già in posizione, ticket 04). Git lo inizializza l'utente.
- `swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]` con TODO: il floor è il minimo compilabile, ogni primitiva privata è validata per build (sezione 6); language mode 6; isolamento di default **per target**: `nil` su `SeatCore`, `MainActor` su facility e Session, nessuno sui target di test (ticket 06). Upcoming feature: `MemberImportVisibility`, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `ExistentialAny`.
- Toolchain `xcrun swift` (Xcode 27, Swift 6.4); la CLI swiftly 6.3.2 crasha sui test del package (ticket 04). `Makefile` minimo: `SWIFT := xcrun swift` e `test`, `host-tests`, `live-tests`, `bench`, `compat-report`, `promote-build`.
- Consumatori: AgentSeatLab ora, Orchestrator poi. Nel kit non compaiono Lab, Planner, Codex, Gemma.

## 3. Stile

`CODE_STYLE.md` e `CLAUDE.md` del kit (già scritti in `AgentSeatKit/`), derivati da `fEditorEngine/CODE_STYLE.md` e dalle regole Reix: `public` esplicito e deliberato; protocolli con nome di ruolo (`WindowRelocating`), mai suffisso `Protocol`; `///` su ogni tipo e membro con il nome del simbolo come soggetto; `//` al massimo due righe; mai em-dash; header `//  File.swift` / `//  AgentSeatKit` / `//  Created by Eliomar Alejandro Rodriguez Ferrer on DD/MM/YYYY.`; colonne allineate anche ai call site; parentesi di apertura a fine riga e di chiusura da sola; property wrapper su riga propria; al massimo due tipi top-level per file; cartelle per concern con sottocartelle libere. Nomi dal glossario `CONTEXT.md` (nel kit). Nel Lab niente `typealias` di transizione. Errori: un tipo per facility, messaggi in inglese con campi strutturati. Log: `os.Logger` subsystem `dev.forte.AgentSeatKit`, una categoria per facility; `os_signpost` C senza argomenti su categoria `DynamicTracing` (l'unica forma a zero allocazioni, ticket 05).

## 4. Moduli, cartelle, grafo

| Target | Ruolo | Contenuto (origine nel Lab) | Import permessi |
|---|---|---|---|
| `SeatCore` | tipi puri e contratti | `WindowReference`, `WindowIdentity`, `WindowGeometryObservation`, `FrameGeometryObservation`, `InputLocation/Command/Receipt`, `PhysicalCursorRegion`, `PhysicalDisplayRecoveryPolicy`, `VirtualWindowPlacementCheck`, `SeatGuard` e `RecoveryPolicy`, `CursorMotionAudit`, `SeatIssue`, `FacilityReadiness`, `FrameDifference`, predicati geometrici, `pauseIgnoringCancellation` | tipi CoreGraphics, zero chiamate OS |
| `PrivateSymbols` | build, simboli, ledger, permessi | `BuildIdentity` (`kern.osversion`, `hw.model`), tabella dei simboli risolta una volta, `RecordLayout` con round-trip, `Ledger`, gate fail-closed, `Permissions.preflight/request` | Darwin, CoreGraphics, ApplicationServices, SeatCore |
| `VirtualScreens` | vita del display virtuale e topologia fisica | `VirtualDisplay`, `TopologyBaseline`, `DisplayList`, `PhysicalDisplay`, attesa `NSScreen` (`ScreenRegistration`), `DisplayFailure` (l'errore dell'intera facility Display) | CoreGraphics, AppKit solo per `NSScreen`, SeatCore, PrivateSymbols |
| `WindowPlacement` | geometria, ordine e ricollocazione delle finestre | `WindowServerProbe`, `WindowRelocator` (`AXPosition`, `AXRaise`, `_AXUIElementGetWindow`) | CoreGraphics, ApplicationServices, AppKit, SeatCore, PrivateSymbols, VirtualScreens |
| `SeatInput` | Input | `InputDriver`, `InputPlatform` con `AppKitPlatform` e `ChromiumPlatform`, preparazione dello stato AppKit | CoreGraphics, SeatCore, PrivateSymbols, WindowPlacement |
| `CursorGuard` | Fence | `CursorFence`, condiviso nel processo con conteggio | CoreGraphics, SeatCore, PrivateSymbols |
| `SeatCapture` | Capture | stream IOSurface, `SeatFrame` con identità/geometria per frame, `Monitor`, `MonitorLayer`, `still`, `shareableContent`, configurazione | ScreenCaptureKit, CoreMedia, QuartzCore, IOSurface, SeatCore, WindowPlacement |
| `SeatSession` | orchestrazione | `SeatHost`, `AgentSeat`, `Turn`, `SeatObserver`, watchdog, recupero, teardown | tutte le facility |
| `TargetReader` | osservazione in sola lettura, linkabile da un consumatore | `WindowReader`, `ObservedWindow` (identità e geometria), lettore dell'albero AX che restituisce `[AXElementNode]`, risoluzione della finestra AX | ApplicationServices, AppKit, WindowPlacement |
| `SeatBench` | misura | JSON schema Reix, budget come costanti Swift | tutte le facility, `AllocationCounter` |
| `AllocationCounter` | conteggio delle allocazioni | hook C su `malloc_logger` | C puro |

**Nessun ombrello (decisione dell'utente, 09/09/2026).** Il target `AgentSeatKit` con i suoi `@_exported import` è cancellato: ogni consumatore importa i moduli che usa, e ogni target dichiara ciò che importa anche quando il modulo gli arriverebbe per transitività, così che separare i pacchetti più tardi sia spostare target e nient'altro. I **prodotti** restano due: `AgentSeatKit` con gli otto target che conducono una seduta e `TargetReader` da solo, perché un prodotto è un'unità di link e non un modulo.

**Emendamento del 09/09/2026 (decisione dell'utente).** Il kit non spedisce nessuna applicazione: `AgentSeatFixture` è cancellato come target. Le app di test (la fixture strumentata con il layout corretto, il suo IPC, `MetalPulseView`, `AXFocusSentinel`) restano del consumatore, e tutto il backend delle loro funzioni chiama il kit. Il tier Live localizza il bersaglio strumentato con `AGENTSEAT_FIXTURE_APP`, così il kit non nomina nessun consumatore, e salta quelle righe quando la variabile non c'è. Dalla sonda esce anche l'interpretazione: categoria e azioni di un elemento le deriva chi chiama, dal ruolo. **Una sola scrittura resta ammessa**, `AXManualAccessibility` sui bersagli Chromium, perché è la precondizione della lettura e non un'azione sul bersaglio: senza quell'interruttore un'app Electron espone una manciata di elementi e nessun testo (decisione dell'utente, 09/09/2026).

**Emendamento del 09/09/2026, clipboard: chiusa (decisione dell'utente).** Ne' il verbo ne' il modulo. `InputCommand` resta a **cinque casi** e `SeatClipboard` e' cancellato.

Il motivo e' misurato, non stimato. Un Comando-V instradato **arriva** a entrambe le famiglie di bersagli e **nessuna lo esegue**, e la stessa cosa vale per ognuna delle **undici strade** provate: la rotta pubblica, il record privato non timbrato, timbrato con finestra e connessione come fa il mouse, timbrato con la Preparazione, `AXUIElementPostKeyboardEvent`, `SLEventPostToPid`, la pressione via accessibilita' sulla voce Incolla del menu, e il menu contestuale aperto col click destro o chiesto via AX. Un equivalente da tastiera lo risolve il **menu dell'applicazione**, e il menu appartiene a chi e' davvero in primo piano, che e' cio' che il seat non puo' mai diventare. Il window server accetta i record (ritorno 0 sempre) e AppKit non li risolve mai, quindi **il fallimento e' silenzioso**: nessun codice distingue eseguito da ignorato. Il rilevatore resta come test Live, costruito dai due eventi grezzi: il giorno in cui una build li esegue, la corsa fallisce.

Sul menu contestuale il negativo e' piu' largo del previsto e vale anche per il ticket 12: **in un'app in background non si apre affatto**, su entrambe le famiglie, con o senza Preparazione.

Il modulo e' cancellato perche' senza incolla non ha un consumatore possibile, e la strada che *funziona* per mettere testo in un bersaglio in background non usa la clipboard: e' la **scrittura del valore di accessibilita'** dell'elemento a fuoco, che entra senza un solo evento e con una sola notifica di modifica. Sta nel consumatore, non nel kit, per l'invariante di questa spec: il kit riceve coordinate, non alberi. E non e' universale — verificata su una finestra nativa e su un browser lanciato con `--force-renderer-accessibility`, **non utilizzabile su un editor a framework**, dove il valore riletto e' indietro di almeno una scrittura e quindi non si puo' confermare. Su quei bersagli si digita, ed e' cio' che il kit sa fare da sempre.

I fatti misurati restano in `docs/spi-ledger.md`, che e' il posto di un fatto senza codice: le undici strade con i loro esiti, la forma del record di tastiera, la finestra di corsa di `changeCount`, e la lettura di un tipo promesso che solleva un'eccezione non catturabile da Swift e **uccide il processo che legge**.

Grafo: `SeatCore ← PrivateSymbols ← {VirtualScreens ← WindowPlacement, SeatInput, CursorGuard} ← SeatSession`; `SeatInput` dipende anche da `WindowPlacement` per identità e geometria; `SeatCapture` dipende da `SeatCore` e da `WindowPlacement` per attestare le sorgenti finestra; `TargetReader` dipende da `WindowPlacement`, e nessuna facility importa `TargetReader`.

```
Sources/
  SeatCore/{Input, Window, Fence, Display, Guard, Readiness, Frames, Errors}
  PrivateSymbols/{Build, Symbols, Records, Ledger, Permissions, Errors}
  VirtualScreens/{VirtualDisplay, Topology, Errors}
  WindowPlacement/{Relocation, WindowServer}
  SeatInput/{Driver, Platforms, Preparation, Errors}
  CursorGuard/{Fence, Audit, Errors}
  SeatCapture/{Stream, Frames, Monitor, Quality, Errors}
  SeatSession/{Host, Seat, Turn, Observer, Recovery, Errors}
  TargetReader/Observation, SeatBench/, AllocationCounter/
Tests/
  <Modulo>Tests/<Concern>/           unit, swift test, parallelo
  HostTests/                         AGENTSEAT_HOST_TESTS=1, .serialized
  LiveTests/                         AGENTSEAT_LIVE_TESTS=1, fixture e reader, matrice per piattaforma
  Benchmarks/Baselines/<kern.osversion>-<hw.model>.json
  LiveTests/Fixtures/                probe-page.html, corpus (a target's resources
                                     have to sit inside that target's directory)
docs/                                 README, spec, adr/, spi-ledger.md, compatibility/<build>.md
```

## 5. API pubblica

### SeatHost
`init(configuration: SeatHostConfiguration)` (`refreshRate` 60 default, 120 ammesso), `start() async throws`, `stop() async`, `makeSeat() throws -> AgentSeat`, `state: off | starting | ready | degraded | failed`, `events: AsyncStream<SeatEvent>`, `monitor: Monitor`, `displayID`. `start` accende display virtuale e recinto in un passo atomico: se uno fallisce l'altro viene smontato. v1: un seat per host e un host nel processo; il modello ammette `n`. Issue di host (`displayChanged`, `fenceUnavailable`, puntatore nel virtuale) → `failed`, tutti i seat `failed`, teardown fail-closed con rilascio best effort delle finestre; `monitorUnavailable` → `degraded`. Watchdog: otto verifiche (display principale, geometria fisica, display virtuale online via `CGGetOnlineDisplayList`, tap attivo, tap mai disabilitato, puntatore fuori dal virtuale, puntatore nella regione fisica, posizione leggibile) a eventi (callback del tap, `CGDisplayRegisterReconfigurationCallback`) più heartbeat a 1 s. `stop`: rilascio delle finestre, rimozione del display (attesa ≤ 2 s), ripristino delle origini fisiche solo se l'insieme dei display coincide con la baseline, altrimenti `topologyChangedByUser`. (Ticket 10.)

### AgentSeat
`state: unavailable | starting | ready | acting | waiting | recovering | degraded | failed`; `events: AsyncStream<SeatEvent>`.
- **Turn**: `acquire() async throws -> Turn` in fila FIFO, cancellabile; `Turn.generation` monotona e `seatChangedSinceLastHold` (generazione cambiata → il chiamante ri-percepisce); `release(_ turn:) throws` solo con ogni Command confermato. Lease, epoch, TTL, priorità, revoca sono del SeatBroker di Orchestrator, costruito sopra il Turn.
- **Finestre**: `adopt(_ window: WindowReference, platform: any InputPlatform = .universal) async throws -> AdoptedWindow` (spostamento via `AXPosition`, due letture del WindowServer di conferma); ogni finestra è `staged` (a dimensione piena, una per host) o `stashed` (miniatura di Stage Manager); `stage(_:)` = `AXRaise` con due letture di conferma (0,5 s su Chrome, 19 ms sulla fixture, nessuna attivazione, ticket 16); `release(_ window:, .returnToUserSeat | .leaveOnVirtualDisplay)`; la chiusura non è del kit.
  L'adozione riconosce anche una miniatura ancora sul display fisico dopo `AXPosition`: esegue lo staging prima della conferma di contenimento, senza attivare l'app. Un errore o un annullamento dopo il tentativo di spostamento avvia il ritorno al frame originale, verificato da due letture della stessa identità. `lastAdoptionFailure` conserva causa, geometria precedente al rollback ed esito; `hasPendingWindowRestorations` segnala un ritorno non confermato, che blocca il seat e viene ritentato dal teardown. Il ritorno può essere accantonato su un display fisico: in quel caso richiede due letture del corpo AX al frame originale, la stessa identità WindowServer con miniatura fuori dal virtuale e topologia fisica invariata. L'errore originale, compreso `CancellationError`, resta quello lanciato al chiamante. Il teardown attende la conclusione dell'adozione in corso.

- **Azione**: `send(_ command:, to: AdoptedWindow, turn:, platform:?) async throws -> InputReceipt` porta on stage se serve, prepara se la piattaforma lo chiede, posta, ripristina, allega una `SeatObservation`; `sendSequence([InputCommand])` prepara una volta e ripristina una volta; `confirm(_ receipt:, _ effect: EffectConfirmation)` con `observed | absent | unknown` (non confermato = `unknown`, nessun timeout).
- **Errori**: `turnRequired`, `seatNotReady(state)`, `seatLimitReached`; nessuna coda dentro `send`, la sola attesa è in `acquire()`.
- **Issue**: di seat critiche (`processUnavailable`, `identityChanged`, `cursorInterference`, `ambiguousEffect`, `recoveryExhausted`) → `failed` del solo seat; `targetActivated` → `waiting` senza scadenza (si esce per cancellazione o quando l'app torna inattiva; mai ricollocare un'app attiva); `windowUnavailable`, `geometryChanged`, `snapshotChanged` → `recovering`; `windowStashed` per uno stage fallito.
- **Recupero**: letture del WindowServer, non AX; cadenza 250 ms, 2 letture stabili, 3 ricollocazioni, 5 s di finestra non leggibile, poi `recoveryExhausted`; attende il Command in volo entro la sua durata massima, oltre il Command vale `unknown`; `unknown` su Issue recuperabile → `failed(.ambiguousEffect)`, mai replay; `observed` chiude la storia, `absent` permette il reinvio.
- **Osservazione**: ogni azione porta `SeatObservation` (frontmost cambiato, Space cambiato, main display cambiato, distanza massima del cursore, ordine delle finestre, bersaglio passato davanti all'app utente, audit del cursore); il kit riporta, non attribuisce. (Ticket 10.)

### Input
`WindowReference(identity, frame)`; `InputLocation(screenPoint, windowPointFromTop, observedGeometry)`; `InputCommand: key(virtualKey, text, flags) | text(String) | insertText(String) | click(location, button: .left | .right) | drag(points, flags:) | scroll(location, deltaY)`; il drag è costruito come l'attuale `pacedDrag` (mouseMoved iniziale, 8 passi intermedi, tempi realistici). Prima di costruire gli eventi il driver rilegge identità, frame e scala: trasla tutti i punti solo se dimensioni, scala e layout locale sono invariati; resize, cambio scala, crop ambiguo o identità diversa richiedono una nuova osservazione. Dopo costruzione e routing rilegge la stessa geometria immediatamente prima del primo post e rifiuta qualsiasi variazione, senza rebuild o replay. Finestra e connessione vengono dalla `WindowIdentity` attestata e sono scritte con `setIntegerValueField` ai campi 51 e 52, il punto locale con `CGEventSetWindowLocation`; `SLEventRecordPointer` resta per il controllo 0xF8 e il round-trip del gate. Le coordinate legacy prive di osservazione restano compilabili ma non autorizzano input live. (Ticket 02, 05, 07, 09.)
`InputPlatform` (protocollo pubblico, `Sendable`): `preparation(for: InputCommand) -> .none | .internalAppKitState`, `preparationSettle(for:)` (**30 ms** di default: entrambe le famiglie applicano la preparazione entro 20 ms in ogni caso misurato, più metà di margine; **150 ms** su Chromium per il solo `insertText`, dove 30 ms inserisce sette volte su dieci e 150 dodici su dodici), `dragPacing`, `decorate(_ event:, for:)` con default vuoto. `AppKitPlatform` non prepara mai; `ChromiumPlatform` prepara `click` sinistro, `drag` e `insertText`; tastiera, testo, scroll e **click destro** passano senza (sul destro la preparazione è dannosa: il suo ripristino posta una disattivazione che il tracking del menu legge come cambio di applicazione e smonta il menu contestuale a 440 ms), vale anche per Electron e CEF; `.universal` = `ChromiumPlatform`, default di `adopt`. La preparazione sono i due record `SLPSPostEventRecordTo` (attivazione e key-window nel solo processo bersaglio), con ripristino garantito anche su errore; se fallisce, nessun evento viene inviato (`InputFailure.preparationFailed(code)`). `InputReceipt(eventCount, route, preparation, timing, observation, unvalidatedBuild)` strutturato, niente prosa. (Ticket 11.)

### Capture e Monitor
`SeatFrame: Sendable { surface: IOSurface, pixelBuffer: CVPixelBuffer (BGRA), presentationTime, receivedAt, displayGeneration, source, geometry, pixelSize, makeCGImage() }`; `source` distingue display, finestra attestata e Window ID legacy non verificata. `geometry` conserva per ogni sample `screenRect`, `contentRect` in punti nella superficie, `scaleFactor`, `contentScale`, dimensione pixel e versione locale dell'osservatore; non è una generazione atomica del WindowServer. Solo un frame finestra attestato, completo, senza shadow/clip e con mapping uniforme può produrre coordinate. Chi lo riceve ne trattiene al massimo uno (pool `queueDepth` 3); il percorso Monitor conserva l'IOSurface fino a `CALayer.contents`, mentre `makeCGImage()` crea intenzionalmente una copia stabile. Due stream con `start(configuration:)`/`stop()` espliciti e `frames: AsyncStream<SeatFrame>` `bufferingNewest(1)`: `SeatHost.monitor` (filtro display, per l'umano) e `AgentSeat.capture` (filtro finestra, per l'osservazione); il kit è il solo owner. Le sorgenti finestra vengono attestate prima e dopo `SCShareableContent`, confrontano il PID pubblicato da SCK e vengono rilette per frame con simboli e gate già cached; una discordanza pubblica `.failed(.windowIdentityChanged)` e ferma l'esatto stream senza fingere un callback Apple. `AgentSeat.capture.still(timeout: 2 s)`: scatto one-shot della finestra adottata (`SCScreenshotManager`), `CaptureFailure.timedOut` allo scadere. Diff prima/dopo in `SeatCore.FrameDifference`; `capturePair` non è API. `MonitorConfiguration(targetFrameRate: 30 | 60 | 120, output: .backing | .fixed(size))`, default 60 e backing; pipeline IOSurface `IOSurface → CALayer.contents` (ticket 03); degrado automatico fps → risoluzione su tasso di coalescenza (primario) e CPU dall'heartbeat (secondario), evento `monitorQualityChanged`, `Monitor.quality`; 120 solo con `refreshRate` 120, da validare con contenuto a 120 Hz. La lettura di CPU passata alla politica è la quota **attribuibile al Monitor**, non il totale del processo, perché il budget di 8 % è netto: misurato in fase 6, il bench alimentato col totale ha degradato un Monitor che costava 3 % netti, perché la scena che filmava ne costava 6,5. Chi non sa attribuire una quota non passa nulla. `MonitorLayer: CALayer` fornito; l'`NSView` è del consumatore. (Ticket 05, 12.)

### System
`BuildIdentity(osVersion: kern.osversion, productVersion, hardwareModel: hw.model)`; `SymbolTable` risolta una volta per facility; `RecordLayout` (0xF8, offset con round-trip); `Ledger`; `FacilityReadiness: validated(build) | unvalidated(build | hardware) | unavailable(reason) | permissionMissing(kind)`; `allowUnvalidatedBuild` per facility; `Permissions.preflight/request(.postEvent | .screenRecording | .accessibility)` che non prompta mai da solo. Regole di caricamento: risolvi a runtime, verifica build, valida dimensione e layout, una sola route esplicita, osserva effetto, fail closed, mai fallback globale.

## 6. Gate di versione macOS

(1) **Ledger** `Sources/PrivateSymbols/Ledger/validated-builds.json`: una voce per build con hardware come lista; per primitiva `kind` (`symbol | class | selector | field | record | behavior`), `image`, `state` (`verified | limited | untested`), `checks` (risoluzione, lunghezza record, offset con round-trip, effetto); verdetto per facility **derivato**; dentro anche i comportamenti fragili di API pubbliche (`CGDisplayIsOnline` a `0xFFFFFFFF` per un display rimosso, default reali di `SCStreamConfiguration`, rilascio del `CGVirtualDisplay` che rimuove il display, finestra con frame globale rimessa sul principale); le primitive scartate in `docs/spi-ledger.md`. (2) **Suite di compatibilità** (`make compat-report`), cinque passi per primitiva: risoluzione, forma dell'ABI, cross-validazione (campi 51 e 52 contro 0x3C e 0x40, `CGEventSetWindowLocation` contro 0x20 e 0x28, `SLSGetWindowOwner` sulla propria finestra), effetto Live (display creato e rimosso, tap installato, matrice per piattaforma sulla fixture, stream con frame `complete`, `still`), referto `docs/compatibility/<build>.md` con differenze dalla build precedente e bozza JSON accanto; `verified` richiede tutti i passi. (3) **Readiness a runtime**: auto-controlli 1-3 sempre all'accensione della facility; `validated` solo se ledger e auto-controlli concordano; `unavailable` se un auto-controllo fallisce anche con ledger favorevole; `unvalidated(build | hardware)` fuori ledger, rifiuto salvo `allowUnvalidatedBuild` per facility (default false, mai sopra un auto-controllo fallito, marcato su Receipt ed eventi). Promozione umana con `make promote-build BUILD=…`, mai automatica, mai con `inconclusive`. (Ticket 07, 08, 14.)

## 7. Concorrenza

Isolamento di default per target (sezione 2). `InputDriver` è un `actor`. **`VirtualDisplay` è invece una classe `@MainActor` senza attese interne** (ADR 0007, misurato in fase 4): un display virtuale avanza solo mentre `NSApplication` pompa eventi, quindi un'attesa che blocca trattiene il thread che avrebbe dovuto pompare e un'attesa `async` restituisce il thread al runtime della concorrenza, che su un `async main` chiude il processo a metà corsa. Il ciclo di vita è del chiamante: il kit espone i predicati e chi chiama li interroga girando la propria pompa eventi. Il recinto gira su un `Thread` dedicato con run loop proprio a `.userInteractive` e il suo callback non ha dipendenze sincrone esterne né allocazioni; la consegna dei frame è fuori dal main, l'applicazione al layer sul main; `SeatHost`, `AgentSeat` e la registrazione `NSScreen` sono sul main actor; i tipi puri sono `nonisolated` e `Sendable`. I protocolli di ruolo nei moduli `facility` si scrivono `nonisolated` (ticket 06).

## 8. Test e budget

Tre livelli: Unit (`swift test`, puri, paralleli), Host (`AGENTSEAT_HOST_TESTS=1`, TCC e display, `.serialized`), Live (`AGENTSEAT_LIVE_TESTS=1`, fixture e reader, la matrice del ticket 02 per ogni `InputPlatform` fornita, `probe-page.html` in `Tests/Fixtures`). `SeatBench` produce JSON nello schema Reix con provenance completa; baseline per coppia build-hardware; budget come costanti Swift. Misure: `mach_absolute_time`, hook `malloc_logger`, `proc_pid_rusage` con tick convertiti; ogni misura ha un controllo sottratto; footprint come HWM dopo meno HWM prima (ticket 05, 13).

| Cosa | Budget |
|---|---|
| callback del recinto (riposo, ancora, audit) | 0 allocazioni; p99 ≤ 50 µs; mai oltre 1 ms |
| `send` di un click (esclusa l'attesa di preparazione) | 0 allocazioni attribuibili; tetto p95 200 µs, poi 2 × p95 misurato dopo ogni fase; mai oltre 1 ms. **Fase 5**: p95 attribuibile misurato a 0 (l'invio intero è più veloce del controllo che costruisce e posta gli stessi due eventi), quindi il budget scende alla varianza del controllo, 10 µs |
| `makeEvents` / preparazione | ≤ 6 allocazioni e ≤ 5 µs / **500 µs p95**: i 100 µs erano una stima mai misurata, e un ciclo di preparazione sono quattro round trip al WindowServer (133-147 µs p50, 213-250 µs p95, fase 5). Le allocazioni della preparazione stanno dentro `SLPSPostEventRecordTo` e non sono attribuibili al kit |
| seat idle (display, recinto, heartbeat) | CPU mediana ≤ 0,1 %, p95 ≤ 1 % su ≥ 5 min; risvegli ≤ 5/s; footprint attribuibile ≤ 4 MB |
| monitor 1920×1080 a 30 e 60 fps | CPU netta ≤ 8 %; latenza p95 ≤ 2 ms; ≤ 12 MB netti; coalescenza ≤ 1 %; 120 provvisorio ≤ 12 % |
| display: setup / rimozione | ≤ 800 ms p95 senza settle / ≤ 200 ms p95 |
| `stage` di una finestra accantonata | ≤ 1 s p95 |
| recupero da Issue recuperabile | `ready` entro 2 s p95 |
| attesa di preparazione | minimo passante fra 20, 40, 80 ms + 50 % → **misurata in fase 5: la matrice passa a 20 ms su entrambe le famiglie, quindi il default è 30 ms** |
| dimensione (LoC, byte `.o` per modulo) | riportata, non gate |

Regressione: violazione di budget = fail; oltre 10 % dalla baseline su p95 (latenze) o media (CPU, footprint) = fail, mediana di 3 corse per le latenze; load alto = `inconclusive`; prima corsa su build-hardware nuova = `no-baseline`, mai pass. Le primitive private hanno tre livelli di test (unit su layout e tabella simboli, host su risoluzione e round-trip, live sull'effetto).

## 9. Migrazione strangler

Il Lab linka il kit dal workspace e sposta un file alla volta: build verde a ogni passo, test portati insieme al file, call site aggiornati ai nomi nuovi senza typealias. Nove fasi, una per sessione, dettagliate in `implementation/01..09` e in `research/09-seatcontroller-cut.md` (destinazione funzione per funzione delle otto bande di `SeatController`): 1 Core, 2 System, 3 Fence, 4 Display, 5 Input, 6 Capture, 7 Session, 8 Probe e Fixture, 9 ricablaggio e cancellazioni. La matrice del ticket 02 è il collaudo di accettazione dopo le fasi 5 e 7.

## 10. Workspace e documentazione

`Research_locator/AgentSeatLab.xcworkspace` (già in posizione, variante A): `FileRef` al progetto e a `../AgentSeatKit`, nessun `XCLocalSwiftPackageReference` nel progetto, dipendenze di prodotto senza `package =`; il Lab si apre dal workspace, il solo `.xcodeproj` non compila. Documenti del kit: `README.md` in inglese senza link al vault; `CODE_STYLE.md`; `CLAUDE.md`; `CONTEXT.md` (canonico nel kit); `docs/spec.md` (questo documento); `docs/spi-ledger.md`; `docs/compatibility/<build>.md`; `docs/adr/0001-0009`. `KitLinkProbe.swift` nel Lab sparisce al primo uso reale del kit.

## 11. Fuori dal kit

Planner e client LLM; osservazione AX (nel Lab e in Orchestrator); lease, epoch, capability, SeatBroker; code di messaggi per agente, rilevamento delle allucinazioni, sostituzione dell'agente; validazione multi-seat e benchmark B1-B9 del vault; pulizia della UI del Lab oltre il ricablaggio; collaudi reali del Lab.

## 12. Piano di implementazione

Ticket in `implementation/`, uno per fase, ognuno con scopo, file d'origine, consegne, criteri di fatto e riferimenti. Ordine obbligato; ogni fase termina con Lab verde dal workspace, `xcrun swift test` verde, bench senza regressioni oltre il 10 % e, dove indicato, matrice del ticket 02 verde.

## Riferimenti

`research/01-baseline.md` (numeri del Lab), `02-input-recipes.md` (ricetta unica, addendum click nudo), `03-monitor-zero-copy.md`, `04-xcode-wiring.md`, `05-measurement-apis.md`, `06-package-settings.md`, `07-record-offsets.md`, `08-spi-drift.md`, `09-seatcontroller-cut.md`, `10-session-states.md`, `11-input-platform.md`, `12-capture-api.md`, `13-budgets.md`, `14-compat-ledger.md`, `16-stage-primitive.md`. Harness riusabili: `research/01-baseline/`, `02-input-recipes/`, `03-monitor-zero-copy/`, `07-record-offsets/`.
