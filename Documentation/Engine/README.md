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
| `EngineCore` | pure types and contracts: `ActOutcome` and its closed kinds, `ActVerification` with `ActOracle` and `OracleEvidence`, `ActionVerb`, `ActionPolicy` and `ActionPermissions`, `ActivationPolicy`, `ActionTiming`, `ActionRequest`, `ElsewhereGuide`, `PopupRowPick`, `CaptureSurface`, and the roles `Actuating`, `SceneProviding` (whose `PerceivedWindow` carries the capture's quality and surface), `ControlPressing`, `ApplicationActivating`, `EffectExpecting`, `ActionObserving` (whose `ActionRecord` and `InputRecord` carry the perceptions an action or an input used) |
| `Engine` | `ActionEngine`: the act cycle and the observe side (`describeScene`, `describeSection`, `checkGoal`) over the roles |
| `HIDActuation` | the foreground `Actuating`: synthetic events at the HID system tap |
| `AccessibilityActions` | `ControlPressing` over the live accessibility tree: open a dropdown by its own press, read a combo box's value, read a toggle under a point |
| `WorkspaceActivation` | `ApplicationActivating` over AppKit's workspace |
| `Memory` | what the agent remembers, pure: `AppKnowledge` (observed objects per window state, menu commands, the brain, routes), `UIBrain` with `ObjectAnchor`, `SiblingGroup`, `LearnedTransition`, `BrainMatcher`, `BrainUpdater` and `BrainRetention`, `Route`, `RouteEarning`, `Recall` with `RecallEvidence` and `SightingGraph`, `Allowlist`, `KnowledgeCoding`, the role `KnowledgeStoring` with `InMemoryKnowledgeStore`, and `BrainMemory`, which fills `EffectExpecting` and enriches scenes from the stored brain (`BrainReading`); and the contracts of the living memory, pure: the observation contract (`ObservationKind`, `CaptureSample` with `CaptureElement`, `MemoryEventRecord`, `SceneSkeleton` and `SceneStructureMatcher`, `SceneDefinition`), the brain's storage and applications (`BrainStoring`, `BrainApplicationStoring` with `BrainApplicationCommand` and `BrainApplicationKey`, `BrainKeys`, `DecayReport`, `BrainClock`, `TransitionEffectRecord`), the agent calls (`AgentCallStoring` with `AgentTool`, `AgentCallRequest`, `AgentCallRecord`, `AgentCallProgress`, `AgentCallResult`, `ObservedEffect`), the menu commands as data (`MenuCommandStoring`), the observed inputs and explicit attributions (`ObservedInputStoring`, `VerificationStoring`, `TaskAttributionStoring`), the procedures and experiences (`RouteStoring`, `StepOccurrenceStoring`, `ExperienceStoring`), the brain's general graph (`BrainGraphStoring`, `MemoryOverview`) and the read of traces (`MemoryTraceReading`); the store's answers (`MemoryStoreError`, `MemoryReceipt`, `MemorySchemaMismatch`, `MemoryTextFault`, `MemorySnapshotRefusal`) |
| `FileKnowledge` | `KnowledgeStoring` over one JSON file per application: write-behind, a directory lock, daily backups, quarantine and restore; and `FileAllowlistStore`. No source imports it since the Brain moved to SQLite; `mecum` still lists it as a dependency and the `MecumEngine` library vends it. The JSON files it wrote are not read at run time |
| `SQLiteMemory` | the living memory's SQLite store, composed by `AutomationRuntime`'s `MemoryService`: `SQLiteMemoryStore` opens one file, bootstraps schema 1 from the module's one DDL resource and refuses any other shape, runs typed write and read transactions over a serial writer and a separate reader, checkpoints passively, copies the file through the backup API (`snapshot(to:)`) and reports the reader's `data_version`; the `SQLite*Repository` types fill the `Memory` roles above, one transaction per write. 46 of the 48 tables are contract data with a typed writer and reader; `brain_scene_roles` and `brain_scene_labels` are projections written and not read. See [the memory schema](MemorySchema.md) and [the memory contracts](MemoryContracts.md) |
| `memory-probe` (tool, `Tools/Engine/memory-probe`) | a second real process on one store file for the module's tests and `measure-memory-store.sh`: driven by lines on its standard input, one answer per line; a package executable, bundled nowhere |
| `LiveScenes` | `LiveSceneProvider`, the `SceneProviding` for a window on the real screen: census, capture (the union with an open pop-up), pipeline |
| `SeatDriving` (`Sources/Integration`) | the Driver's seat filling the Engine's roles: `SeatTarget` owns the host, the seat and the adopted window; `SeatSceneProvider` is `SceneProviding` over the seat's stills; `SeatActuator` is `Actuating` over routed Commands inside a Turn, answering every receipt with what the engine saw; `SeatControls` is `ControlPressing` without the geometric read |
| `AutomationRuntime` (`Sources/Integration`) | the composition root: `EngineRuntime` wires the foreground adapters or the Seat's, the expectations from `BrainMemory` over the directory's `MemoryService`, and the call's `CallRecorder` as the engine's observer. `MemoryService` is the one living memory of a Knowledge directory in the process (`shared(for:)`): `memory.sqlite`, opened on first use, written through one ordered queue no action waits for, read with a Brain cache, copied once a day; `CallRecorder` records one call (its request, start and end, its samples and what it taught the Brain); `ActionContext` is who acts under which trace; `MemoryClock` keeps the facts' calendar, the Brain's clock and durations apart. `AutomationSession` is the foreground application session, `AutomationSessionOperating` the role the tools drive |
| `AutomationMCP` (`Sources/Integration`) | `AutomationTools`, the seventeen tools over `AutomationSessionOperating`; each call it answers is recorded under its `CallProducer` (the app's worker, an external MCP client, the CLI chat) when the session names a memory, and a memory that cannot be written never stops a tool |
| `mecum` (tool, `Tools/Engine/mecum`) | the command line: `windows`, `scene`, `act`, `select`, `batch`, `memory` (an application's Brain, or `--import-json <dir>` to copy earlier JSON Brains into the archive); the composition root that wires the foreground adapters, or the Seat's with `--seat` |

Before the first SeatDriving observation reaches the Engine, `SeatTarget`
requires the full attested identity of the adopted window, including its process
lifetime and owner connection. A different selection refuses before exposing a
scene; after the first match, ordinary window following remains available.
The borrowed target receives the broker's adopted identity explicitly so a
selection change before borrowing cannot redefine the opening target.

Link the `MecumEngine` library product. `EngineCore` imports `PerceptionCore`, Foundation and
CoreGraphics; `Memory` imports `EngineCore` and `PerceptionCore`; the adapters import their core
module and one framework, `FileKnowledge` imports `Memory` and Foundation only, and `SQLiteMemory`
imports `Memory`, Foundation and the SDK's `SQLite3`. In production it is imported by
`AutomationRuntime` (`MemoryService`, `CallRecorder`) and by `mecum`'s `memory` command; no library
product vends it. A background seat fills
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

With memory, the same engine learns from what it does and reads what it learned, and each call
leaves its facts in the living memory of the Knowledge directory:

```swift
let runtime   = EngineRuntime(knowledgeDirectory: knowledgeDirectory) // the process's MemoryService for it
let recorder  = runtime.recorder(ActionContext(source: .cli, streamID: stream, traceID: trace))
let engine    = runtime.engine(recorder: recorder, allowsDestructive: false)
let perceived = try await runtime.scenes.currentScene(of: pid)
let scene     = await recorder.observe(perceived)  // the current sample, the Brain's ingest, the enriched scene
let outcome   = await engine.act(request)          // before/after samples; an effect is recorded in the Brain
await runtime.finish()                             // waits up to the closing budget for queued writes
```

Every write is queued on the service and the call goes on; only an observation waits, at most
50 ms, for the queue (its own ingest included) before it enriches the scene. The call's own row (planned, started, its
end) is written when a producer calls `CallRecorder.begin` and `end`, as `AutomationTools` does for
every tool call; the command line's `scene` and `act` write the event, its samples and the Brain's
learning, with no call row.

From the terminal, the same composition is the `mecum` tool. Screen Recording and Accessibility must
be granted to the terminal that runs it.

```bash
swift build --product mecum
.build/debug/mecum windows "Pro Tools"                      # the census: what is driven, what is a pop-up
.build/debug/mecum scene "Pro Tools"                        # the text map a model reads; also teaches the brain
.build/debug/mecum act "Pro Tools" "EditModeSpot"           # resolve, click, verify: found_acted or an honest miss
.build/debug/mecum act "Pro Tools" "Solo" --verb set_toggle --value on --section "Audio 1"
.build/debug/mecum memory "Pro Tools"                       # the archive's Brain: anchors, groups, worth naming
```

Measured on this Mac against Pro Tools on the first run: a 589-element scene in 1.5 s, an act in 1.4 s
including its two perceptions, 399 anchors and 45 sibling groups learned from two looks, and two
transitions recorded from two verified clicks.

## Driving on the Seat

Text containing supplementary Unicode or line breaks uses one intact insertion
payload, even below the 128-character typing threshold. App-flow checks found
per-character input dropping emoji in Qt, Chrome and Electron, while insertion
preserved it. Field selection and exact readback still decide the result; no
unconfirmed edit is automatically replayed. See the
[application flow checks](../Driver/reports/ApplicationFlowChecks.md).

`insert_text` exposes the same single payload through the CLI chat and Mecum
app tools, at a focus and selection the caller has already established. It
sends no focusing click or selection keys, which preserves a modal's initially
selected name. `expected_value` is the complete resulting value; only matching
native focused-field readback verifies it. An opaque field remains
`acted_unverified`, even when OCR looks right. Observe before more input and
verify any committed effect independently; never replay an uncertain insertion.

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

`select` resolves the current dropdown in a fresh captured scene, requests its native `AXShowMenu`,
and observes the separate menu window through the Driver's WindowServer sensing. It captures
that attested menu alone, requires a unique visible item, and invokes `AXPress` only on a unique
matching menu item whose accessibility rectangle lies inside the observed popup. The native
request is never retried on an AX timeout: Pro Tools can leave its menu open while returning
`cannotComplete`. The Seat uses its existing menu cleanup on success, a missing item, cancellation
and errors. No global click or foreground fallback is used.

Success requires the requested value to appear at the original dropdown in a fresh capture after
the menu closes. `--evidence /tmp/mecum-dropdown` saves local `before.png`, `menu.png` and `after.png`.
Full-window scenes and native opener lookup use the captured process, window number and geometry.
An AX title need not equal the WindowServer title. Missing identity or stale geometry refuses;
titles and focus do not provide another candidate. Native popup/combo values drive arrow routing
and effect verification when available; a matching editor or neighbouring value proves nothing.
See [ADR 0027](../Driver/adr/Adr0027BindDropdownLookupToCapture.md).
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
  leaves both unknown.
- `ActionObserving` receives every action's and every input's record once the outcome is decided:
  the element, the verb or input, the effect the scenes attributed, how far the gesture got, and the
  perceptions the engine used (`before`, `after`, and for a contextual menu choice the `menu`). An
  input's perceptions are gathered in a task-local `InputTrail` and change no decision. A conformer
  records or drops; it never fails the action.
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
- The `windows` tool reads window candidates through `AutomationSessionOperating`.
  The broker uses its adoption discovery policy, including qualified nonminimized
  standard AX windows kept offscreen by Stage Manager. Listing opens no Seat and
  grants no input authority; adoption still reattests the candidate.
- A pop-up is a window of its own. A target inside an open pop-up is chosen with the keyboard from
  `PopupRowPick`'s plan over the scene's rows (the highlight starts on the control's value, the arrows
  wrap, Return chooses), verified by reading the control's value back. An item of an open native menu
  is pressed through its accessibility element first; only when none answers is the menu's own
  type-ahead used, committed only while the list is still open, and that pick answers
  `acted_unverified`: the menu closing does not confirm the command ran. A target outside an
  open pop-up closes it first and answers `acted_noop`, because clicking through a menu hits the menu.
- A closed dropdown is opened by its own press action when the application exposes one, so a painted
  caret is never the click target. The press is never used to pick: it toggles, and an option often
  shares the control's current text.
- `found_acted` carries the effect's summary; every `acted_unverified` carries the `ElsewhereGuide`
  sentence, which names a window that opened, closed or retitled outside the perceived one, or says
  that no such window transition was observed. An unchanged census cannot prove the absence of an
  effect inside a window; unclassified pixel changes require reading the intended result before
  deciding on further input, without repeating the click solely from that verdict.
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
  deleted. Production mutates it only through `BrainApplicationStoring`, where one key (an
  observation's sample, an action's event) is one application: a retry answers the stored outcome,
  another command under the key is a conflict, and the application's clock never runs backwards.
  The one other writer is `mecum memory --import-json`, which writes a whole Brain only for an
  application the archive holds none of.
- A recorded call is a fact, not a success (`AgentCallStoring`): `completed` means the call
  concluded, its outcome keeps its own meaning, a skipped batch step is never shown as run, and the
  arguments are the ones the tool decoded, with its defaults written once. `AutomationTools`
  records each call it can represent planned and started before the tool runs and ends it with the
  result the tool answered (an outcome with the effect the engine observed, a listing's rows, an
  observation tied to its real sample, a batch's summary, `close_session`'s answer) or `failed` with
  its error. Those writes are queued in that order; the tool does not wait for them, and nothing is
  replayed.
- The memory never holds up a tool (`MemoryService`): writes run one after another on the
  service's own task, a busy archive is waited out by that task alone, and a write that fails or
  arrives at a full queue (4096 writes) is a counted gap, logged and shown by `status()`, never an
  error for the caller. An archive that cannot be opened degrades the service with its reason;
  reads answer no opinion and writes are gaps until it opens again after its interval. Nothing
  resets or replaces the file, except a file the library calls corrupt, which is moved aside and
  replaced by the newest daily copy, or by an empty archive when there is none.
- Three times, kept apart (`MemoryClock`): the facts' calendar as the wall said it, kept even when
  it ran backwards; the Brain's clock, a reference plus the monotonic time elapsed, never backwards
  within the process; and durations from monotonic readings of one process. A session's own
  observation after `open_session` belongs to an observation event that names the call it was
  taken for (`origin_event_id`), a durable relation apart from a batch's parent.
- A stored menu command is data, not a choice (`MenuCommandStoring`): its identity is an id the
  producer chose, never the joined path or the accessibility identifier; nothing runs, merges or
  scores a command, and no producer writes one yet.
- Inputs, correlations, verifications, episodes and labels are facts and stated attributions:
  nothing observes, correlates, judges, segments or labels on its own. The Watcher
  (`InteractionListener`, `mecum watch`) is not connected to the memory.
- A procedure is a definition, not a script (`RouteStoring`): publication checks its structure,
  never its reliability, and authorizes no replay; changing a published Route is a new version.
  The brain's projection owns only the transitions `LearnedTransition` represents; every other arc
  lives in the general graph, which nothing in production writes.
- A route is a belief: only a proof (`RouteEarning.verdict` over the outcomes its own steps cover,
  and an answer that does not hand the work back) may create one, a contradiction demotes it, and
  demotion never erases. Steps store semantic targets, never coordinates, and never typed text.
- Recall answers `fire`, `hint` or `abstain`, and every slot it fills itself must name something
  concrete: an application the graph knows by a whole component or an end of one, or an entity
  sighted inside the targeted application. "Seen but not trusted" is narrated; "never seen" is silent.
  `Route`, `RouteEarning` and `Recall` work over `AppKnowledge` and are called by tests only: no
  production path earns a route or recalls one in this checkout.
- `KnowledgeStoring` serializes its own mutations, and a load after a mutation returns sees what
  the mutation wrote whether or not it has reached disk. No storage type appears in a public API of
  the pure module; the file adapter takes its directory, clock and diagnostics at construction.
- `SQLiteMemoryStore` answers a write only after its commit. A busy lock is waited for between
  attempts, outside any transaction and with the caller's cancellation; `write` holds the work
  cycle after cycle of the lock budget until the commit, the cancellation, the close or a failure
  that is not contention, and `attemptWrite` runs one cycle and answers `contention`. A constraint,
  a trigger, a missing bound value or an over-long text is `contract`; a path that cannot be opened
  is `open`; a file whose version, tables, columns, indexes or triggers are not exactly the ones
  this build creates is `schema`, and the file is left as found. Text is bound and read by its
  byte length and read strictly: a stored text that is not valid UTF-8 is `malformedText`, never
  replaced. Foreign keys are enabled and verified per connection, the file is in WAL, and no
  statement outlives the call that prepared it.

## Evidence

Unit: `ActVerificationTests` (one test per verdict), `ActOracleTests` (11: the three oracles, the exact
typed-value transition, a landed effect a contradicted oracle demotes, the unchanged no-oracle path and
the interrupted reading), `ActionPolicyTests`, `ElsewhereGuideTests`,
`PopupRowPickTests` (Premiere's measured list geometry), and `ActionEngineTests`, which drives the
whole cycle through doubles that honor the roles: resolution and its misses, the destructive gate,
dry runs, a landed click, a ghost, a repaint with a window that appeared elsewhere, expectation by
family, menu gating, activation, a dropdown opened by press, delivery failure, `set_toggle`'s three
answers, the keyboard pick, type-ahead, and the pop-up dismissal; `CaptureSurfaceTests` (2) the
surface classification. `MemoryTests` (162 in 19 suites, `swift test list`, 2026-10-07) covers the
knowledge containers and their legacy JSON, the brain (anchors, groups, ordinal rescue, identity
hygiene from measured Premiere failures, enrichment, the naming ledger, decay and the observation
clock), routes and route earning against the real `route-corpus.json`, recall against the real
`misfire-corpus.json` and its human table, the in-memory store's serialization, the `BrainMemory`
seam over a stored Brain, structure-v3 on synthetic skeletons, the brain's two seams for its stored
projection, and the contracts of calls, results, sample keys and content, menu commands, inputs
and attributions, and procedures. `FileKnowledgeTests` (7) proves the file adapter at its boundary:
round-trip, write-behind and scheduled flush, two hundred concurrent increments, daily backups with
pruning, and quarantine with restore. `SQLiteMemoryTests` (227 in 43 suites) proves the store and
its repositories on temporary files, with `memory-probe` for the proofs that need a second
process, and `verify-memory-schema.py` runs 242 SQL checks on the shipped resource in `make test`;
both are listed in [the memory schema](MemorySchema.md#verification).
`AutomationRuntimeTests.MemoryWiringTests` (15) proves the wiring on temporary directories: the
queue's order and its limit, a refused archive degraded and left as found, the daily copy and the
recovery of a corrupt archive, a call recorded through its recorder with its samples, effect and
Brain record, the open's own observation with its origin, a call outside the tools, a batch's
steps, the Brain cache, the tools' calls under their producer, and three latency measures. The
other adapters are proven at their framework boundary on a Mac.

## Not here yet, in porting order

1. `Scrolling`: the scroll and reach machinery, over `Actuating` and `SceneProviding`; reach reads
   `UIBrain.revealers` so a name behind a dropdown is never hunted by scrolling.
2. The experience and sighting stores behind `Recall.World`, and read-hit accounting with them.
   `SQLiteMemory` has every repository of schema 1; production writes the calls, samples, scene
   associations and Brain applications through `MemoryService`. The Watcher's inputs, the menus,
   tasks, Routes and experiences have repositories and fixtures, not producers, and nothing searches
   or recalls over them ([the memory contracts](MemoryContracts.md)).
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

## Passive user interaction diagnostics

The independent [interaction listener](../Interactions.md) exposes `mecum watch` for inspecting
manual input, window attribution and production perception. It does not feed the Brain or memory.

For external Claude and Codex clients using the running macOS app, see
[Local MCP connections](LocalMCP.md).
