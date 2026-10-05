# Engine

For the provider/model picker, saved conversations and persistent background tool sessions,
see [CLI chat](Chat.md). Start with `mecum --chat`.

How the agent acts on what it sees: perceive this instant, resolve a target by name, refuse what
policy refuses, deliver a gesture through a role, perceive again, and judge the effect by what
changed structurally. The layer knows which application it is driving only as a process id and a
name; it never imports an input mechanism, a window system or a model.

The point of the layer is the one rule it will not bend. `found_acted` requires a structural effect.
An identical scene is a ghost; a changed scene with nothing attributable is a repaint. Both answer
`acted_unverified` with a sentence that says which, because a wrong success costs more rounds than
an honest miss: it was measured as a model burning turns on a click that never happened.

## Oracles

Some gestures have a second reading that settles what two scenes cannot, and `ActOracle` names the
three this layer knows: the surface the gesture was aimed at is gone from the window server's list,
the field reads the value it had with the typed text inserted into it, or the control no longer
shows the state it had. It is derived before the gesture goes out, from the action and the surface
it is aimed at, never from the picture, and it is consulted before the scene difference. An oracle
that holds is `found_acted` however little else moved, and the sentence says which reading decided
it. An oracle the reading contradicts leaves `acted_unverified` with that contradiction said out
loud, including where the difference alone would have called the gesture landed: a structural change
the oracle does not cover is a measurement, not the proof this gesture was for. An action with no
oracle is `nil` and the two-scene rule is exactly what it was. `OracleEvidence` is what a
composition root read and nothing it inferred: the after-scene, which `SceneAugmenting` has already
put the live accessibility value and state on, and whether the window server still lists the
surface, which is `WindowListing`'s answer in the foreground and the seat's own on the seat. No role
is written beside it, because both readings already have one. When no after-scene could be taken at
all, `ActVerification.interrupted` still asks the surface's identity: a Cancel that closed its panel
stays closed while the focus is coming back, and anything else is uncertain, which is not a failure
and is never a reason to send the gesture again.

## Shape

| Module | What it owns |
|---|---|
| `EngineCore` | pure types and contracts: `ActOutcome` and its closed kinds, `ActVerification` with `ActOracle` and `OracleEvidence`, `ActionVerb`, `ActionPolicy` and `ActionPermissions`, `ActivationPolicy`, `ActionTiming`, `ActionRequest`, `ElsewhereGuide`, `PopupRowPick`, `CaptureSurface`, and the roles `Actuating`, `SceneProviding` (whose `PerceivedWindow` carries the capture's quality and surface), `ControlPressing`, `ApplicationActivating`, `EffectExpecting`, `ActionObserving` |
| `Engine` | `ActionEngine`: the act cycle and the observe side (`describeScene`, `describeSection`, `checkGoal`) over the roles |
| `HIDActuation` | the foreground `Actuating`: synthetic events at the HID system tap |
| `AccessibilityActions` | `ControlPressing` over the live accessibility tree: open a dropdown by its own press, read a combo box's value, read a toggle under a point |
| `WorkspaceActivation` | `ApplicationActivating` over AppKit's workspace |
| `Memory` | what the agent remembers, pure: `AppKnowledge` (observed objects per window state, menu commands, the brain, routes), `UIBrain` with `ObjectAnchor`, `SiblingGroup`, `LearnedTransition`, `BrainMatcher`, `BrainUpdater` and `BrainRetention`, `Route`, `RouteEarning`, `Recall` with `RecallEvidence` and `SightingGraph`, `Allowlist`, `KnowledgeCoding`, the role `KnowledgeStoring` with `InMemoryKnowledgeStore`, and `BrainMemory`, which fills `EffectExpecting` from the stored brain (`BrainReading`) and carries what a producer observes or records to `BrainApplicationStoring`, once per key; and the observation contract of the living memory, pure: `ObservationKind` (the versioned registry), `CaptureSample` with `CaptureElement`, `MemoryEventRecord`, `SceneSkeleton` and `SceneStructureMatcher` (structure-v3), `SceneDefinition` and `SceneAssociation`, with the roles `CaptureStoring` and `SceneStoring`; and the brain's storage role `BrainStoring` with the pure pieces a stored projection needs: `BrainKeys` (who names a new anchor or group), `DecayReport` (what a decay dropped and why), `BrainClock` (canonical milliseconds) and `TransitionEffectRecord` (an effect as typed columns); and the application contract a producer uses, `BrainApplicationStoring` with `BrainApplicationCommand` (a call normalized once), `BrainApplicationKey`, `BrainApplicationOutcome`, `BrainApplicationResult` and the versioned `BrainApplicationContract` of its arguments; and the agent calls' contract, `AgentCallStoring` with `AgentTool`, `AgentCallRequest` (a call's arguments normalized once), `AgentCallRecord`, `AgentCallStatus`, `AgentCallResult`, `AgentCallProgress`, `AgentCallTransition`, `AgentCall` and the versioned `AgentCallArguments`; and the menu commands as data, `MenuCommandStoring` with `MenuCommandRecord` (an explicit id, the observed fields, sightings as canonical milliseconds) and `MenuCommandError`; and the observed inputs and explicit attributions, `ObservedInputStoring`, `VerificationStoring` and `TaskAttributionStoring` with `ObservedInput`, `ObservedInputRecord`, `ActionCorrelation`, `VerificationRecord`, `TaskOccurrenceRecord`, `TaskMembership`, `TaskLabelRecord`, `TaskAttribution` and `EventFactError`; and the procedures and experiences, `RouteStoring`, `StepOccurrenceStoring` and `ExperienceStoring` with `RouteDefinition`, `ProcedureStep`, `StepCheck`, `StepOperation`, `RouteCallBinding`, `RouteState`, `StepOccurrenceRecord`, `StepMembership`, `DefinitionEvidence`, `ExperienceRecord`, `ExperienceBinding`, `ExperienceUse` and `RouteError`; and the brain's general graph, `BrainGraphStoring` with `BrainArc`, `SceneElementRecord`, `BrainEvidenceRecord` and `MemoryOverview`; and the diagnostic read of traces, `MemoryTraceReading` with `TraceSummary` and `TraceEntry` |
| `FileKnowledge` | `KnowledgeStoring` over one JSON file per application: write-behind, a directory lock, daily backups, quarantine and restore; and `FileAllowlistStore`. No executable or composition root links it since the living memory moved to SQLite; the `MecumEngine` library still vends it, and the files it wrote are left unread |
| `SQLiteMemory` | the living memory's SQLite foundation, composed by `AutomationRuntime`'s `MemoryService` and imported nowhere else: `SQLiteMemoryStore` opens one file at a chosen path, bootstraps schema 1 from the module's one DDL resource, runs typed write and read transactions over a serial writer and a separate reader, checkpoints the log passively, and copies the file through the backup API (`snapshot(to:)`); `SQLiteLibrary` reports the linked library; `SQLiteCaptureRepository` and `SQLiteSceneRepository` fill `CaptureStoring` and `SceneStoring` over it, the first typed repositories, and `SQLiteBrainRepository` fills `BrainStoring`: the stored projection of `UIBrain`, mutated by `BrainUpdater` inside one write transaction, for tests and low-level tools; `SQLiteBrainApplicationRepository` fills `BrainApplicationStoring`: each observation, record or naming applied once per key, with its input, outcome, effective clock and evidence, in the same transaction; `SQLiteAgentCallRepository` fills `AgentCallStoring`: a call's event, row and typed arguments in one transaction, a batch with its steps, and the call's states, with no tool run and nothing replayed; `SQLiteMenuCommandRepository` fills `MenuCommandStoring`: a command and its ordered path in one transaction, explicit updates against the record last read, reads per command and per application; `SQLiteObservedInputRepository`, `SQLiteVerificationRepository` and `SQLiteTaskRepository` fill those three roles: an input or a verification with its event in one transaction, correlations, attributions and episodes as stated, nothing inferred; `SQLiteRouteRepository`, `SQLiteStepOccurrenceRepository` and `SQLiteExperienceRepository` fill the procedure, occurrence and experience roles; `SQLiteBrainGraphRepository` fills `BrainGraphStoring`: scene elements and their anchors, general arcs beside the projection's own transitions, evidence of the six targets, and an overview of the file; `SQLiteTraceRepository` fills `MemoryTraceReading`: the traces most recent first, a trace's events with their calls, the observations a call originated, read only. Forty-six of the 48 tables are contract data with a typed writer and reader, whose readers check the relations their writers check; `brain_scene_roles` and `brain_scene_labels` are projections of a scene's skeleton, written and not read. What it answers with is `Memory`'s: `MemoryStoreError`, `MemoryReceipt`, `MemoryIdentityConflict`, `MemoryTextFault`, `MemorySnapshotRefusal`, `ObservationContractError`. See [the memory schema](MemorySchema.md) and, for what Action Memory and Action Recall build on, [the memory contracts](MemoryContracts.md) |
| `memory-probe` (tool, `Tools/Engine/memory-probe`) | a second real process on one store file for the module's tests and the cost measures: driven by lines on its standard input, one answer per line; a package executable, bundled nowhere |
| `LiveScenes` | `LiveSceneProvider`, the `SceneProviding` for a window on the real screen: census, capture (the union with an open pop-up), pipeline |
| `SeatDriving` (`Sources/Integration`) | the Driver's seat filling the Engine's roles: `SeatTarget` owns the host, the seat and the adopted window; `SeatSceneProvider` is `SceneProviding` over the seat's stills; `SeatActuator` is `Actuating` over routed Commands inside a Turn, answering every receipt with what the engine saw; `SeatControls` is `ControlPressing` without the geometric read; `SeatDropdownSelector` answers a `SelectionResult` with the windows it read |
| `AutomationRuntime` (`Sources/Integration`) | the composition root: `EngineRuntime` wires the foreground adapters or the Seat's over the owner's `MemoryService`, the one living memory of a Knowledge directory (`memory.sqlite`, opened on first use; a busy archive waited out cycle after cycle under each caller's own cancellation, at the open, on a read and on a write; degraded as a state only for a true failure; closed by its owner), handed to the engine's seams as `BrainReading`, `BrainApplicationStoring`, `CaptureStoring`, `SceneStoring` and `AgentCallStoring`, with `finalize` for the facts that already exist (not cut by the caller's cancellation; a busy archive waited out like any write while the caller is not cancelled; once stopped, one budget for all the facts of the owner, `MemoryFinalizationScope`: a turn, a call outside a turn, a vertical command's invocation; `FinalizationTrace`, off unless `MECUM_MEMORY_FINALIZATION_TRACE` names a file, says each step of it on two monotonic clocks for a live proof) and `MemoryClock` keeping the facts' calendar, the Brain's clock (a reference plus monotonic time) and monotonic durations apart; `ActionContext` is who is acting and under which trace, passed with every call, and names the call a session's own observation was taken for; `CallRecorder` writes one call's samples and the brain's learning as finalizations and reports what it saw; `MemoryReading` is the memory as a reader sees it (status, a reader's open, overview, Brain, traces, calls, events, samples, associations), the one dependency of the app's Brain library and of the command line's diagnosis, with `BrainCatalog` telling a missing archive, an unreadable one and an empty one apart; its open, `MemoryService.openForReading`, takes only an existing Mecum archive (`SQLiteMemoryStore.Opening.existingArchive`), creates and changes nothing, joins the owner's open in flight and leaves the service as it was when it refuses; `AutomationSession` is the foreground application session, `AutomationSessionOperating` the role the tools drive |
| `AutomationMCP` (`Sources/Integration`) | `AutomationTools`, the 14 tools over `AutomationSessionOperating`, which record every call in the memory (planned and started before any effect, with the task's cancellation ending the call there; concluded with the result each tool represents, typed rows for `status`, `windows`, `apps`, `open_session` and `observe` included, the typed observed effect and the monotonic duration, as a finalization; a batch with its steps) and never stop for a memory that cannot be written; `ToolRequestDecoder`, the one decoder of a call and of a batch step into `AgentCallRequest`, which the `mecum` direct commands share, with the batch's one acceptance rule (`AgentCallRequest.accepts`); `ToolEnvironment`, the host's permissions and windows as the listing tools read them, a seam for fixtures |
| `AgentTurn` (`Sources/AgentTurn`) | the one turn of an agent over a desktop session, run by the app's worker and by `mecum chat` alike: `AgentTurnHost` owns the tools over the session, the loopback MCP host and its connection file, the provider child or Mecum's own loop over a model transport (`ModelToolLoop`), the instructions, the turn as the provider receives it, the stop and the cleanup, and reports `AgentTurnEvent`s in order; `TurnUsage` and `ContextCompaction` are what a turn cost and a context's compaction, as the app records them ([CLI chat](Chat.md)) |
| `mecum` (tool, `Tools/Engine/mecum`) | the command line: `windows`, `scene`, the seven actions of the app's tools as direct commands and `batch` steps (`act`, `select`, `type_text`, `press_key`, `scroll`, `drag`, `context_menu`, read by `ActionGrammar` into the tools' decoder and recorded by `StepRunner`), and `memory` (`status`, `traces`, `trace`, `event`, an application), which reads the archive with no application open (`MemoryDiagnosis`); the composition root that wires the foreground adapters, or the Seat's with `--seat`; its chat drives the desktop through `SeatBroker`'s `BrokeredAutomationSession`, the app's session, and runs each turn through `AgentTurn`, the app's turn core, with the same 14 tools and a worker's configuration (`--role`, `--effort`, `--web-search`; [CLI chat](Chat.md)) |

Link the `MecumEngine` library product. `EngineCore` imports `PerceptionCore`, Foundation and
CoreGraphics; `Memory` imports `EngineCore` and `PerceptionCore`; the adapters import their core
module and one framework, `FileKnowledge` imports `Memory` and Foundation only, and `SQLiteMemory` imports
`Memory`, Foundation and the SDK's `SQLite3`, and is imported by `AutomationRuntime` alone, where
`MemoryService` owns the file. A background seat fills
`Actuating` with its own delivery and leaves `ApplicationActivating` unfilled: its windows are never
in front and its gestures need no raising, which is why the engine treats that role as optional.

## Using it

```swift
let engine = ActionEngine(ActionEngine.Dependencies(
    scenes    : sceneSource,                 // a SceneProviding over the Perception pipeline
    actuator  : HIDActuator(),
    windows   : WindowServerWindowListing(),
    controls  : AccessibilityController(),
    activation: WorkspaceActivator()
))
let outcome = await engine.act(ActionRequest(
    processID: pid, bundleID: "com.adobe.PremierePro", appName: "Adobe Premiere",
    target: "96000", verb: .click
))
outcome.kind      // .foundActed, .actedUnverified, .actedNoop, .ambiguous, .honestMiss, .refused, .dryRun
outcome.message   // one sentence a model can act on next
outcome.scene     // the scene after acting, so no second perception is paid to see what happened
```

With memory, the same engine learns from what it does and reads what it learned, and every call
leaves its facts in the living memory of the Knowledge directory:

```swift
let memory   = MemoryService(directory: knowledgeDirectory)      // one memory.sqlite under it, opened on first use
let runtime  = EngineRuntime(memory: memory)                      // the brain's seams read and apply through it
let context  = ActionContext(source: .cli, streamID: stream, traceID: invocation, sessionID: session)
let recorder = runtime.recorder(for: context)                     // one per call: its samples, its learning, its report
let engine   = runtime.engine(allowsDestructive: false, observer: recorder)
let scene    = await recorder.observe(perceived)                  // the current sample, the brain's ingest, the enriched scene
let outcome  = await engine.act(request)                          // before/after samples, the effect as evidence
let report   = await recorder.report()                            // the effect for the call's row, notes if memory refused
await memory.close()                                              // the owner's, last
```

The call itself (its event, arguments and states) is recorded by the producer around the engine:
`AutomationTools` for the app and the chat, `CLICall` for the vertical commands.

From the terminal, the same composition is the `mecum` tool. Screen Recording and Accessibility must
be granted to the terminal that runs it.

```bash
swift build --product mecum
.build/debug/mecum windows "Pro Tools"                      # the census: what is driven, what is a pop-up
.build/debug/mecum scene "Pro Tools"                        # the text map a model reads; also teaches the brain
.build/debug/mecum act "Pro Tools" "EditModeSpot"           # resolve, click, verify: found_acted or an honest miss
.build/debug/mecum act "Pro Tools" "Solo" --verb set_toggle --value on --section "Audio 1"
.build/debug/mecum memory "Pro Tools"                       # the archive's Brain: anchors, groups, transitions
```

Measured on this Mac against Pro Tools on the first run: a 589-element scene in 1.5 s, an act in 1.4 s
including its two perceptions, 399 anchors and 45 sibling groups learned from two looks, and two
transitions recorded from two verified clicks.

## Driving on the Seat

For clicks, a native interactive control wins over a same-name plain-text caption. In Pro Tools'
New Paths dialog, `act "Pro Tools" "Create" --window "New Paths"` therefore chooses the Create
button rather than the word at the start of the sentence. Two matching native controls remain
ambiguous; exact element IDs and explicit section filters retain precedence. Ambiguity hints use
an element ID when no section exists instead of suggesting the unusable `section:'?'`.

With `--seat` the same commands run in the background: the window is adopted onto the Driver's
virtual display, the stills come from the Seat's capture, every gesture is a Command routed to the
adopted window inside a Turn, the application is never raised, and the window is returned when the
command ends. `--allow-unvalidated-build` is the Driver's research opt-in for a macOS build its
ledger has not validated, said out loud on stderr.

```bash
.build/debug/mecum scene "Pro Tools" --seat --allow-unvalidated-build
.build/debug/mecum act "Pro Tools" "EditModeSpot" --seat --allow-unvalidated-build
```

For a native dropdown, opening and selection must share one Seat lifetime. With Pro Tools'
I/O Setup already open on the Bus tab:

```bash
.build/debug/mecum select "Pro Tools" "All Busses" "Output Busses" \
  --window "I/O Setup" --seat --allow-unvalidated-build
```

To chain operations in an already-open window without returning it between commands, use `batch`:

```bash
.build/debug/mecum batch "Pro Tools" --window "New Paths" --seat --allow-unvalidated-build -- \
  select "Mono" "Stereo" --then \
  act "Auto-create sub paths" --verb set_toggle --value on --then \
  act "Create"
```

The app and shared options precede `--`; `--then` separates steps. The whole argument list is
validated before creating a Seat. One Seat, virtual display and memory runtime serve the sequence;
each step uses fresh perception and the same verified `select` or `act` implementation as standalone
commands. `set_toggle --value on` leaves an already-checked box alone. A plain `act` still means click.
Dropdown evidence goes into `--evidence <dir>/step-N` subfolders.

The batch stops at the first failure, ambiguity, unverified effect, cancellation or unavailable
original target, reports the step number and exits nonzero after cleanup. An `acted_noop` only
continues for `set_toggle` when the desired state was already observed; dismissing a menu instead
of clicking the requested target does not complete a batch step. Earlier effects remain and no
step is automatically replayed. The last step may close the dialog. This version requires one
explicit window for the whole batch; it does not switch windows between steps or offer a batch
dry run, since later controls can depend on earlier real effects. Use Cancel instead of Create
when rehearsing this example without adding a path.

Batch evidence, 2026-09-18: a live five-step New Paths sequence selected Stereo, set Auto-create
sub paths off, set it on, verified an already-on no-op, and clicked Cancel. It completed 5/5 with
one target adoption and one display teardown, returning to I/O Setup with Active Busses still
174. A separate missing-menu-item sequence stopped at step 1/2 with exit 1, closed the menu,
returned New Paths to the user, and did not execute its following Cancel step. `BatchTests`
covers whole-plan validation, ordered execution, all rejected outcomes, thrown errors and
cancellation between steps; `ActionEngineTests` also passes after sharing command execution.

`select` resolves the current dropdown label in fresh pixels, requests its native `AXShowMenu`,
and observes the separate menu window through the Driver's WindowServer sensing. It captures
that attested menu alone, requires a unique visible item, and invokes `AXPress` only on a unique
matching menu item whose accessibility rectangle lies inside the observed popup. The native
request is never retried on an AX timeout: Pro Tools can leave its menu open while returning
`cannotComplete`. The Seat uses its existing menu cleanup on success, a missing item, cancellation
and errors. No global click or foreground fallback is used.

Success requires the requested value to appear at the original dropdown in a fresh capture after
the menu closes. `--evidence /tmp/mecum-dropdown` saves local `before.png`, `menu.png` and `after.png`.
The command prints the menu window ID, cleanup method, and observed focus/cursor changes. It adopts
companion app windows before the requested window and returns the requested window last.
`act` also adopts companions, back to front, and enables the Driver's new-window following. When
a clicked dialog disappears, verification can capture its most recent surviving, already-held
predecessor from the same attested process. The scene carries the captured window's title. This
is read-only evidence gathering; it does not retarget input or bypass the Driver's refusal to
recover an action whose effect remains unknown.
Cursor displacement is an observation of all movement, including the user's hand, not attribution
to the command. The CLI owns a non-activating AppKit event loop until the command finishes, as
required by Driver ADR 0007; asynchronous capture must not outlive the executable's main lifetime.

Measured in Pro Tools on 2026-09-18: both All Busses → Output Busses and the reverse changed the
visible value. The reverse run recorded no focus change and zero cursor displacement. A mouse
click routed to the correct menu window dismissed this dropdown without selecting its row, so
that unsuccessful path was removed. Elio's existing right-click context-menu API is unchanged.
Native dropdowns keep their Show Menu and Press path. When a uniquely resolved visible control
has no native Show Menu action, `select` uses the Driver's routed opening click and menu lifecycle.
It captures the virtual display, crops the attested menu rectangle, and uses `PopupRowPick` to
move from the visible current value to the requested item with arrows and Return. It does not
wrap through the visible subset of a scrolling menu. Both values must be readable; missing items
or an unplannable route close the menu without choosing. Each key requires that the same menu
identity and frame still exist, preventing a later Return from reaching the parent if it disappears.
Nested menus and offscreen item scrolling are not supported. `select` remains separate from `act`.

Premiere Format evidence, 2026-09-18: its accessibility tree exposes no native H.264 dropdown;
the old `controlNotUnique` was zero matches, not duplicate controls. An unprepared opener was
ignored, while the adopted platform's prepared click opened its separate menu. Capturing that
menu directly through ScreenCaptureKit produced a scaled parent window instead of menu pixels;
the display crop showed the correct rows. A routed item click was ignored and was removed from
this path. Eight Up keys plus Return selected AAC Audio from H.264, verified in the closed Format
control and the `.aac` filename. The run recorded no focus change and zero cursor displacement.
No export was started. Native menu, routed keyboard lifecycle, cancellation and partial-menu
planning regression tests cover the shared seams (231 tests passed). A missing-item live run
posted zero selection keys, closed the menu with Escape, and left AAC Audio unchanged, again
with no focus change or cursor displacement.

Create regression, 2026-09-18: dry-run selected the bottom-right native button; one live click
closed New Paths and added Bus 25-26 (Stereo), with Active Busses changing from 172 to 174.
That first run reported `acted_unverified` because the old capture target had disappeared.
After adding predecessor capture, a new New Paths → Cancel run reported `found_acted`,
`navigates to I/O Setup`, with the count still 174. Create was not replayed. Opening New Path
itself succeeded but its immediate after-scene still described I/O Setup; this run does not
establish that new-window following settles before the first verification capture.

The final build selected Output Busses with exit 0 and retained foreground focus. A nonexistent
item returned `honest_miss` with exit 1, closed through the Driver's preparation cleanup, and left
the dropdown unchanged. Local evidence: `/tmp/mecum-dropdown-final`,
`/tmp/mecum-dropdown-missing-final`, and their adjacent `.log` files. Regression coverage includes
native selection, missing/ambiguous items, opening failure/timeout, reader cancellation, existing
menus, and cleanup failure in `NativePopupMenuTests`.

For New Paths' format selector, use `--window "New Paths"` and the current value, such as
`select "Pro Tools" "Mono" "Stereo"`. The whole-window text can merge the adjacent caption into
`new Mono`. If exact scene resolution misses, the selector finds one exact native dropdown,
rejects bounds outside the captured window, and re-reads only that control's pixels before
opening it. It verifies the new value in the same region after selection. This does not broaden
global label matching or choose an ambiguous control. Live Mono → Stereo was verified in the
captured dialog with no focus change or cursor displacement; Create was not pressed.

What the Seat's geometry buys: a click is routed only through the last full-window still's own
pixel-to-screen observation, so a point outside the adopted window is refused rather than posted
somewhere, and a pop-up is chosen with the keyboard, which the engine already does. While a pop-up
is open the scene comes from a display still cropped to the union of the window and the pop-up.

Measured on this Mac, Pro Tools adopted from the real screen onto the virtual display: adoption in
0.25 to 0.33 s, a 553-element scene in 1.5 s, two clicks `found_acted` with the expectation the
brain had learned in the foreground. Two things to watch: the window came back at a different size
and origin than it left (the Seat's return, not this layer's), and the multi-window follow the
Driver offers is not yet turned on here.

## Contracts

- `ActVerification.verdict` compares a remembered expectation by effect family, never by exact
  string: a flip's direction or a menu's items may vary, the kind of effect should not.
- `Actuating.perform` returns when the events have gone out and says nothing about their effect;
  the engine verifies by perceiving again, then tells the actuator what it saw through
  `Actuating.confirm`: `observed` for a landed effect, `absent` for a ghost, `unknown` for a
  repaint or a failed delivery. One action's gestures are confirmed together. A foreground
  actuator has nothing to answer; the Seat's answers each receipt and gives its Turn back, which is
  the Seat's own rule that an event that went out is never repeated.
- `SceneProviding.currentScene` is a fresh perception at every call, never a cache: an action is
  resolved against this instant's positions. The `PerceivedWindow` it answers states what the
  provider measured about this one capture: the pipeline's `CaptureQuality` and the
  `CaptureSurface`, which is `popupUnion` while a pop-up is open (two windows in one picture, never
  a structural surface), else classified from the role and subrole the tree reported, else
  `unknown`. Nothing is inferred from the title or the elements; a provider that read no tree
  leaves both unknown. The dropdown selector's own captures carry no tree read and stay unknown.
- The observation contract (`Memory/Observation`) is what the living memory keeps of a capture:
  the sample's identity (event, phase, ordinal; ordinal 0 is the perception the engine used), its
  completeness as the walk measured it, its surface, and its role-bearing elements with label
  origin and the structural path truncated at the collection. `ObservationKind` is a closed,
  versioned registry (`capture`, `capture_field`, `element` at version 1): an unknown code or
  version is refused on the way in and on the way out, never mapped to a known kind.
- Structure-v3 (`SceneStructureMatcher`) compares a complete capture's skeleton with the scenes of
  its application and answers same, different or uncertain per scene; it confirms only one same
  with nothing uncertain, lists candidates otherwise, creates a scene only when every known scene
  is different and the capture is complete, on a window, dialog or sheet, with a structural role.
  Titles, states, values, static text, pixels, counts and everything inside a collection are not
  identity; differing captions or paths are uncertainty, not proof. No threshold, no score, no
  first-candidate pick. The repository runs it inside the transaction that reads the scenes and
  writes the decision, and never re-decides a sample it already decided.
- A pop-up is a window of its own. A target inside an open pop-up is chosen with the keyboard from
  `PopupRowPick`'s plan over the scene's rows (the highlight starts on the control's value, the arrows
  wrap, Return chooses), verified by reading the control's value back; without a readable control the
  menu's own type-ahead is used, committed only while the list is still open. A target outside an
  open pop-up closes it first and answers `acted_noop`, because clicking through a menu hits the menu.
- A closed dropdown is opened by its own press action when the application exposes one, so a painted
  caret is never the click target. The press is never used to pick: it toggles, and an option often
  shares the control's current text.
- `found_acted` carries the effect's summary; every `acted_unverified` carries the `ElsewhereGuide`
  sentence, which names a window that opened, closed or retitled outside the perceived one, or says
  that nothing else changed, so a dead click is never mistaken for a slow one.
- Activation happens only when the application is not in front and no pop-up is open; a menu is
  believed only while a pop-up window exists, and while one does its rows are the effect.
- The engine never sleeps a literal: `ActionTiming` holds every pause with its measurement, and the
  pause itself is a closure supplied at construction, so a test runs without waiting.
- The brain describes, never aims: an anchor's typical bounds are a matching hint and an
  annotation, and every action re-perceives live. Matching is unique-accept throughout, so two
  near-equal candidates are no match and never a forced merge.
- The brain forgets by evidence of absence, measured in observations of the application and scoped
  to the window that was looked at, never by the calendar: an application nobody opens does not
  forget (the 2026-09-06 wipe). A name a person or a model assigned is protected until a
  contradiction retracts it. A state transition is trusted at evidence two; a menu reveal at one.
- The brain's stored projection (`SQLiteBrainRepository`) runs the same algorithms, never new ones:
  load, `BrainUpdater`, difference, in one transaction with the clock as a canonical millisecond
  value. What the algorithm drops is retired with the cause it applied (`DecayReport`), never
  deleted; identities and orders are the algorithm's; `ObjectAnchor.groupID` is its own column,
  apart from the ordered memberships. A raw mutation is applied each time it is asked for; a
  producer applies through `BrainApplicationStoring`, where the same key is one application: a
  retry answers the stored outcome, another command under the key is a conflict, an application
  that changed nothing is concluded too, and the application's clock never runs backwards. The S3
  path calls none of `SQLiteBrainRepository`'s mutations.
- A recorded call is a fact, not a success (`AgentCallStoring`): `completed` means the call
  concluded, its outcome keeps its own meaning, a skipped batch step is never shown as run, and the
  arguments are the ones the tool decoded, with its defaults written once. The producers are
  `AutomationTools` (the app's worker and `mecum chat`) and the `mecum` vertical commands, through
  `MemoryService`; a call is planned and started before its tool runs, and the task's cancellation
  ends it there, wherever it lands, so no effect follows a stop; it is concluded with what the tool
  answered (an outcome with the effect the engine observed as typed parts, a listing's rows, an
  observation tied to its real sample, a batch's summary, what `close_session` said, an error) and
  the monotonic duration of the run, as a finalization the cancellation does not cut (a busy archive
  is waited out; after the turn's stop, the turn's facts share one budget of the service's, then are
  explicit gaps, a call that Mecum's own loop lets finish after the stop included); an effect that
  already happened keeps its known outcome and is never described as undone; a memory that cannot
  be written is one record line and never stops a tool; nothing is replayed.
- The memory never runs the tools: `MemoryService` is a state (ready, degraded with its reason,
  closed), its reasons carry codes and identifiers and never a label or a typed text, a busy archive
  is waited out cycle after cycle and is never a failure, a transaction the store could not end
  degrades the service after that operation, a degraded service tries to open again
  after its interval on the same path, and only its owner closes it. The brain learns where it
  always did (an observed scene, an action with an effect on an element), once per call: the
  sample's key or the call's event is the application's identity, and the instant it is asked for
  is the Brain's clock read once per call, so the same facts offered again are the same command.
- Three times, kept apart (`MemoryClock`): the facts' calendar as the wall said it, kept even when
  it ran backwards; the Brain's clock, a reference plus the monotonic time elapsed, never backwards
  within the process; and durations from monotonic readings of one process, never a difference of
  calendar instants and never compared across processes. A session's own observation after
  `open_session` names the call it was taken for (`origin_event_id`), a durable relation apart from
  a batch's parent.
- A stored menu command is data, not a choice (`MenuCommandStoring`): its identity is an id the
  producer chose, never the joined path or the accessibility identifier; an update is a deliberate
  change against the record last read; nothing runs, merges or scores a command.
- Inputs, correlations, verifications, episodes and labels are facts and stated attributions:
  nothing observes, correlates, judges, segments or labels on its own, an unknown verdict stays
  unknown, and no attribution moves the brain. No Watcher producer exists in this checkout.
- A procedure is a definition, not a script (`RouteStoring`): publication checks its structure,
  never its reliability, and authorizes no replay; a Route call binds parameters by direction and
  type; changing a published Route is a new version. The brain's projection owns only the
  transitions `LearnedTransition` represents; every other arc lives in the general graph, which
  the projection neither reads nor retires.
- A route is a belief: only a proof (`RouteEarning.verdict` over the outcomes its own steps cover,
  and an answer that does not hand the work back) may create one, a contradiction demotes it, and
  demotion never erases. Steps store semantic targets, never coordinates, and never typed text.
- Recall answers `fire`, `hint` or `abstain`, and every slot it fills itself must name something
  concrete: an application the graph knows by a whole component or an end of one, or an entity
  sighted inside the targeted application. "Seen but not trusted" is narrated; "never seen" is silent.
  `Route`, `RouteEarning` and `Recall` are ported over `AppKnowledge` and called by tests only: no
  production path earns a route or recalls one in this checkout.
- `KnowledgeStoring` serializes its own mutations, and a load after a mutation returns sees what
  the mutation wrote whether or not it has reached disk. No storage type appears in a public API of
  the pure module; the file adapter takes its directory, clock and diagnostics at construction.
- `SQLiteMemoryStore` answers a write only after its commit, never for a change waiting in memory.
  A busy lock is waited for between attempts, outside any transaction and with the caller's
  cancellation; the ordinary `write` holds the work in the caller's task, cycle after cycle of the
  lock budget, until the commit, the cancellation, the close or a failure that is not contention,
  so a spent budget is a diagnostic and never a dropped fact; `attemptWrite` runs one cycle and
  answers `contention`, which is not `failed`. A lock inside the connection is `locked`; a
  constraint, a trigger, a missing bound value or an over-long text is `contract`; a path that
  cannot be opened is `open`; a schema this build does not know is `schema`, and the file is left
  as found. An empty archive answers zero rows, an unreadable one answers an error. A close
  prevails over an open or a write still waiting, and no handle survives it; it is not a flush. Text
  is bound and read by its byte length, so a NUL inside it is content, and it is read strictly: a
  stored text that is not valid UTF-8 is `malformedText` by position, never replaced or emptied,
  and stays readable as bytes. A configuration that would let a cycle end without a pause is
  refused at open. After a device or file failure the store ends the transaction the library left
  open and says so in the fault (`cleanup`); a transaction it cannot end makes the instance `failed`
  until closed, and recovery is a new instance on the same path. A snapshot is a verified copy
  through the backup API into a path that must not exist; a checkpoint is passive and reports
  `partial` rather than failing for a reader. Foreign keys are enabled and verified per
  connection, WAL is set once at bootstrap and verified at every open, and no statement outlives
  the call that prepared it. Its one composition root is `AutomationRuntime`'s `MemoryService`.

## Evidence

Unit: `ActVerificationTests` (one test per verdict), `ActOracleTests` (11: the three oracles, the exact
typed-value transition, a landed effect a contradicted oracle demotes, the unchanged no-oracle path and
the interrupted reading), `CaptureSurfaceTests`, `ActionPolicyTests`, `ElsewhereGuideTests`,
`PopupRowPickTests` (Premiere's measured list geometry), and `ActionEngineTests`, which drives the
whole cycle through doubles that honor the roles: resolution and its misses, the destructive gate,
dry runs, a landed click, a ghost, a repaint with a window that appeared elsewhere, expectation by
family, menu gating, activation, a dropdown opened by press, delivery failure, `set_toggle`'s three
answers, the keyboard pick, type-ahead, and the pop-up dismissal. `MemoryTests` (165) covers the
knowledge containers and their legacy JSON, the brain (anchors, groups, ordinal rescue, identity
hygiene from measured Premiere failures, enrichment, the naming ledger, decay and the observation
clock), routes and route earning against the real `route-corpus.json`, recall against the real
`misfire-corpus.json` and its human table, the in-memory store's serialization, the `BrainMemory`
seam end to end, structure-v3 on synthetic skeletons (`SceneStructureMatcherTests`, 5), and the brain's
two seams for its stored projection (`BrainUpdaterSeamTests`, 4: injected keys, the decay report), and
the application command contract (`BrainApplicationContractTests`, 9: with declared counts against
the rows, keys byte for byte in a set, −0.0 and +0.0 as one number), the agent call contract
(`AgentCallContractTests`, 9: the fourteen tools' arguments as typed rows and back, defaults written
once, exact comparison, refusals both ways, the moves between states) and the sample key's and content's bytes
(`CaptureSampleKeyTests`, 1; `CaptureSampleContentTests`, 2), and the stored menu command
(`MenuCommandRecordTests`, 4), and the observed inputs and attributions
(`EventAttributionContractTests`, 5), and the procedures, occurrences, experiences and arcs
(`ProcedureContractTests`, 5). `FileKnowledgeTests` (7) proves the file adapter at its boundary:
round-trip, write-behind and scheduled flush, two hundred concurrent increments, daily backups with
pruning, and quarantine with restore. `SQLiteMemoryTests` (263, in forty-four suites) proves the store on
temporary files: the linked library's version and source id, bootstrap and reopen, an empty archive
apart from an unreadable file, an unwritable path, a future, foreign or incomplete schema refused
untouched, two openers of one file, the rollback of a failed statement, visibility on another
connection, idempotency by identity, one cycle of contention and its cancellation, a wait that holds no
transaction, `locked` apart
from `contention`, a full database, a snapshot read beside an open writer, the closed store; the
lifecycle and the retained writes, synchronized on the store's own wait events (a close during an
open, two opens of one instance, a write held past a whole budget then committed once, ended by
close, ended by cancellation); bindings and readings (a NUL inside text, Unicode, empty text apart
from NULL, blobs, cardinality, repeated placeholders, the length limit); strict text reading (five
invalid sequences refused by position on the writer and on the reader, valid shapes whole); the
waiting policy's limits and its schedule on `WaitingCycle`; snapshots through the backup API (consistency with the log, one
self-contained verified copy that reopens, refusals, cancellation and close between steps, a writer
active in another process); checkpoints (explicit, partial for a pinned reader, the automatic bound);
failure and recovery (a full database with its cleanup reported, a constraint failure rolled back by
the store, the cleanup decision, a real I/O error in another process); two real processes through
`memory-probe` (concurrent bootstrap, idempotency across processes, no lost update among three,
a process killed before its commit, after it, and after its commit but before answering); and the shipped schema
resource: its shape, the three writes the S0 review found admitted, status corrections, and the
app-scope rules on INSERT and UPDATE alike. Three of its suites are the first S2 increment:
the observation contract (registry, vocabularies, the eight fields, and every malformed row refused
on the way out), the capture repository (events and samples once by identity, the round trip after
reopening, the event's summary, a rollback the file forces), and the fifteen structure-v3 fixtures
of the S0 specification through the real producer, with idempotent re-association, the app scope
never a candidate, two stores on one file making one scene, and the signature rebuilt from SQL. Two suites
are its correction (exact comparison, coherent quality, finite geometry). Four are the brain's projection:
the canonical clock; the projection equal, after every step and after reopening, to a pure brain run on
the same sequence with the same keys (the identity-hygiene sequences, groups, overlapping memberships and the current group, aliases,
states, ordinal rescue, impostors, ambiguity, the cap with ties, protected names, the per-window clock,
small ingests, menu reveals, the five effects, retirement causes, reappearance, every active reader,
a scene without accessibility); refusals, rollback, two stores on one file and the earlier form of
schema 1; and the boundaries with Routes, calls, evidence and structural scenes. Three are the brain's
applications: once per key across reopening, stores, samples and a helper process that dies after its
commit, durable no-ops, conflicts field by field, the effective clock, rollback, references, sealing
and evidence sources; and their correction (a declared count checked against the rows before it
sizes anything, in a helper process and through the SQL reader; versions and event ids byte for byte).
Three are the agent calls: the fourteen signatures and a seven-step batch read back exactly, applied
once by their event, moved through their states without an invented success, a partial batch
concluded as stopped, malformed rows refused, two writers and two processes, and a batch summary
held to the one its steps allow under the current producer, the start kept through the end with
the monotone duration and the typed observed effect, and the structured results of the listing and
scene tools; two prove capture identities and sample
content byte for byte; one proves the menu commands (every field and the ordered path, colliding
keys, explicit updates, two callers, malformed rows, the brain's projection beside them); three prove
the Watcher inputs, correlations, verifications, episodes, memberships and labels, and the path from
an input to its attribution after reopening; one the correlation readers' checks; three the
procedures (definitions, publication, composition, versions), occurrences with evidence and
experiences with their uses, and the brain's general graph beside the projection. The 232 SQL checks (the 166 of the S0 review, six of the current group, 30
of the applications register and 30 of a call's start, duration, typed effect, structured results
and an observation's origin) run on the shipped
resource in `make test` (`Tools/Engine/Scripts/verify-memory-schema.py`); see
[the memory schema](MemorySchema.md). `AutomationRuntimeTests` (65, with the S4 measures, the shared
budget after a stop, its opt-in trace and the service after a failed cleanup; the production budget under a real lock
with `MECUM_MEASURE_PRODUCTION=1` and the reads of a kept corpus with `MECUM_COST_ARCHIVE` are opt-in
measures) proves the composition root's
memory service and recorder on temporary databases (the file created on first use; a busy archive
waited out at the open and on a write held over several cycles, committed once; two callers with
one cancelled; a close during the open; a true failure degraded and recovered after the interval;
the definitive close; a finalization not cut by cancellation, waited out under ordinary contention
past the budget and saved once, bounded by the budget only from the stop (during the wait, or at
once for a caller cancelled already), saved when the lock goes within the budget after the stop,
and a stop that abandons no other caller; two services on one directory; the three times kept
apart; safe reasons; the samples and the brain's learning once per call, a retransmission at the
same instant and a conflict at another, a miss, an input's menu, the open's own observation with
its origin, a degraded memory as notes, the supervision's uncancelled observation under a lock held
past the budget, saved with its ingest; the Brain catalogue's three answers with an older JSON file
left unread, a reload that sees another writer's write, and observations recorded with no call; a
reader's open that refuses a zero-byte file, a SQLite file with no schema, another program's tables
and a newer version byte for byte, creates nothing for a missing one, opens a valid archive with no
commit, leaves the owner a producer, joins the owner's open and hands a joined producer its own);
`ChatTests.AutomationToolsMemoryTests` (14) the calls as the tools record them, with the typed
results of the five listing and scene tools, a batch's children, the supervision's cancellation
while planning that reaches no effect, a cancellation after the effect that keeps the outcome, an
effect concluded under ordinary contention past the budget (run once, read back after the release),
monotone durations under a calendar that ran backwards, and the decoder against the definitions;
`SeatBrokerTests` and `MecumCLITests` the session's and the chat's recording through the real
service. The other adapters are proven at their framework boundary on a Mac.

## Not here yet, in porting order

1. `Scrolling`: the scroll and reach machinery, over `Actuating` and `SceneProviding`; reach reads
   `UIBrain.revealers` so a name behind a dropdown is never hunted by scrolling.
2. The experience and sighting stores behind `Recall.World`, and read-hit accounting with them.
   `SQLiteMemory` has every repository of schema 1, and S3-d connected the producers of calls (with
   the structured results of `status`, `windows`, `apps`, `open_session` and `observe`), samples,
   scenes and the brain's applications (the tools, the sessions, the vertical commands) through
   `MemoryService`. The Watcher's inputs, the menus, tasks, Routes and Experience still have
   repositories and fixtures, not producers, and nothing searches or recalls over them: that is the
   work of Action Memory and Action Recall ([the memory contracts](MemoryContracts.md)).
3. `AppAdapters`: Premiere, Pro Tools, Resolve, AppleScript, Chrome, each behind one capability
   role, so the engine never imports a bridge.
4. A native `AgentLoop`. CLI chat currently delegates reasoning and conversation context to
   Claude Code or Codex through the MCP tool adapter; see [CLI chat](Chat.md).

Background actuation/control roles now live in `SeatDriving`. The initial model-facing tool registry
is `AutomationMCP`, over the shared `AutomationRuntime` and `ActionEngine`.

Not a module yet: the CV region segmenter (`RegionSegmenting` has no adapter, so a scene is text
plus accessibility, and an icon with no name and no accessibility role is not seen).

Left behind on purpose: the pixel hover-and-click pop-up path, whose success criterion checked the
hover and not the result (the post-mortem's false green checkmark); file-evidence goal checks, which
belong with the task board; every environment read the previous handlers carried; the menu
explorer's exploration denylist, which belongs with the explorer; and the process-wide memo and
pending singletons, replaced by the store actor's own state.

## Where the previous code went

| Locator | Here |
|---|---|
| `locator-mcp/Server.swift` act verification | `EngineCore/Verification/ActVerification.swift` |
| `locator-mcp/Server.swift` `act`, `describe_scene`, `describe_section`, `check_goal` | `Engine/ActionEngine.swift` |
| `LocatorCore/ActionPolicy.swift` | `EngineCore/Policy/ActionPolicy.swift` |
| `Relocation/ActTiming.swift` (values and `ActivationPolicy`) | `EngineCore/Timing`, `EngineCore/Policy` |
| `LocatorCore/MissGuide.forUnverifiedAct` | `EngineCore/Guidance/ElsewhereGuide.swift` |
| `locator-mcp/Server.swift` keyboard row pick | `EngineCore/Popup/PopupRowPick.swift` |
| `Relocation/LiveActuator.swift` (the static posting) | `HIDActuation/HIDActuator.swift` |
| `locator-mcp/Server.swift` `pressDropdownViaAX`, `dropdownAnchorValue` | `AccessibilityActions/AccessibilityController.swift` |
| `LocatorCore/KnowledgeBase.swift` | `Memory/Knowledge/{ObservedObject,StateFingerprint,WindowInventory,AppKnowledge,Allowlist}.swift` |
| `LocatorCore/MenuKnowledge.swift` (the commands and their matching) | `Memory/Knowledge/{MenuCommand,AppKnowledge+Menus}.swift` |
| `LocatorCore/UIBrain.swift` | `Memory/Brain/*` (one type per file; `BrainUpdater.detectGroups` became `SiblingGroupDetector`) |
| `LocatorCore/Routes.swift` | `Memory/Routes/{GoalPhrase,RouteStep,Route,RoutePolicy,AppKnowledge+Routes}.swift` |
| `LocatorCore/RouteEarning.swift` | `Memory/Routes/RouteEarning.swift` (outcomes are `ActOutcomeKind`, not strings) |
| `LocatorCore/Recall.swift`, `LocatorMemory.{Experience,GraphContext,hint,tokens,core}` | `Memory/Recall/*` (`SightingGraph`, `RecallEvidence`, `MemoryHint`; `core` is `LabelText.coreKey`) |
| `LocatorCore/KnowledgeStore.swift` (+ `KnowledgeMemo`, `KnowledgePending`, `AllowlistStore`) | `Memory/Storage/KnowledgeStoring.swift` (the role), `FileKnowledge/{FileKnowledgeStore,FileAllowlistStore}.swift` |
| `LocatorCore/DescriptorStore.make{Encoder,Decoder}` | `Memory/Knowledge/KnowledgeCoding.swift` |
| `locator-mcp/Server.swift` transition recording after an act | `Memory/Seams/BrainMemory.swift` |
| Mecum `SeatInputBackend`, `AgentSession.captureForLocator` (the Lab's join) | `Integration/SeatDriving/*` |
