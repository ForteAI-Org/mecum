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
| `EngineCore` | pure types and contracts: `ActOutcome` and its closed kinds, `ActVerification` with `ActOracle` and `OracleEvidence`, `ActionVerb`, `ActionPolicy` and `ActionPermissions`, `ActivationPolicy`, `ActionTiming`, `ActionRequest`, `ElsewhereGuide`, `PopupRowPick`, and the roles `Actuating`, `SceneProviding`, `ControlPressing`, `ApplicationActivating`, `EffectExpecting`, `ActionObserving` |
| `Engine` | `ActionEngine`: the act cycle and the observe side (`describeScene`, `describeSection`, `checkGoal`) over the roles |
| `HIDActuation` | the foreground `Actuating`: synthetic events at the HID system tap |
| `AccessibilityActions` | `ControlPressing` over the live accessibility tree: open a dropdown by its own press, read a combo box's value, read a toggle under a point |
| `WorkspaceActivation` | `ApplicationActivating` over AppKit's workspace |
| `Memory` | what the agent remembers, pure: `AppKnowledge` (observed objects per window state, menu commands, the brain, routes), `UIBrain` with `ObjectAnchor`, `SiblingGroup`, `LearnedTransition`, `BrainMatcher`, `BrainUpdater` and `BrainRetention`, `Route`, `RouteEarning`, `Recall` with `RecallEvidence` and `SightingGraph`, `Allowlist`, `KnowledgeCoding`, the role `KnowledgeStoring` with `InMemoryKnowledgeStore`, and `BrainMemory`, which fills `EffectExpecting` and `ActionObserving` from the brain |
| `FileKnowledge` | `KnowledgeStoring` over one JSON file per application: write-behind, a directory lock, daily backups, quarantine and restore; and `FileAllowlistStore` |
| `LiveScenes` | `LiveSceneProvider`, the `SceneProviding` for a window on the real screen: census, capture (the union with an open pop-up), pipeline |
| `SeatDriving` (`Sources/Integration`) | the Driver's seat filling the Engine's roles: `SeatTarget` owns the host, the seat and the adopted window; `SeatSceneProvider` is `SceneProviding` over the seat's stills; `SeatActuator` is `Actuating` over routed Commands inside a Turn, answering every receipt with what the engine saw; `SeatControls` is `ControlPressing` without the geometric read |
| `mecum` (tool, `Tools/Engine/mecum`) | the command line: `windows`, `scene`, `act`, `select`, `memory`; the composition root that wires the foreground adapters, or the Seat's with `--seat` |

Link the `MecumEngine` library product. `EngineCore` imports `PerceptionCore`, Foundation and
CoreGraphics; `Memory` imports `EngineCore` and `PerceptionCore`; the adapters import their core
module and one framework, and `FileKnowledge` imports `Memory` and Foundation only. A background seat fills
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

With memory, the same engine learns from what it does and reads what it learned:

```swift
let store  = FileKnowledgeStore(directory: knowledgeDirectory, clock: { Date() }, diagnostics: { print($0) })
let memory = BrainMemory(store: store, clock: { Date() })
let engine = ActionEngine(ActionEngine.Dependencies(
    scenes: sceneSource, actuator: HIDActuator(), windows: WindowServerWindowListing(),
    expectations: memory,                    // trusted transitions become expectations, by family
    observer    : memory                     // every performed action's effect becomes evidence
))
try await memory.observe(scene)              // anchors the scene's elements, scoped to its window
let annotated = await memory.enrich(scene)   // group tags, affordances, recalled names; positions stay live
```

From the terminal, the same composition is the `mecum` tool. Screen Recording and Accessibility must
be granted to the terminal that runs it.

```bash
swift build --product mecum
.build/debug/mecum windows "Pro Tools"                      # the census: what is driven, what is a pop-up
.build/debug/mecum scene "Pro Tools"                        # the text map a model reads; also teaches the brain
.build/debug/mecum act "Pro Tools" "EditModeSpot"           # resolve, click, verify: found_acted or an honest miss
.build/debug/mecum act "Pro Tools" "Solo" --verb set_toggle --value on --section "Audio 1"
.build/debug/mecum memory "Pro Tools"                       # anchors, groups, transitions, routes
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
  resolved against this instant's positions.
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
- A route is a belief: only a proof (`RouteEarning.verdict` over the outcomes its own steps cover,
  and an answer that does not hand the work back) may create one, a contradiction demotes it, and
  demotion never erases. Steps store semantic targets, never coordinates, and never typed text.
- Recall answers `fire`, `hint` or `abstain`, and every slot it fills itself must name something
  concrete: an application the graph knows by a whole component or an end of one, or an entity
  sighted inside the targeted application. "Seen but not trusted" is narrated; "never seen" is silent.
- `KnowledgeStoring` serializes its own mutations, and a load after a mutation returns sees what
  the mutation wrote whether or not it has reached disk. No storage type appears in a public API of
  the pure module; the file adapter takes its directory, clock and diagnostics at construction.

## Evidence

Unit: `ActVerificationTests` (one test per verdict), `ActOracleTests` (11: the three oracles, the exact
typed-value transition, a landed effect a contradicted oracle demotes, the unchanged no-oracle path and
the interrupted reading), `ActionPolicyTests`, `ElsewhereGuideTests`,
`PopupRowPickTests` (Premiere's measured list geometry), and `ActionEngineTests`, which drives the
whole cycle through doubles that honor the roles: resolution and its misses, the destructive gate,
dry runs, a landed click, a ghost, a repaint with a window that appeared elsewhere, expectation by
family, menu gating, activation, a dropdown opened by press, delivery failure, `set_toggle`'s three
answers, the keyboard pick, type-ahead, and the pop-up dismissal. `MemoryTests` (121) covers the
knowledge containers and their legacy JSON, the brain (anchors, groups, ordinal rescue, identity
hygiene from measured Premiere failures, enrichment, the naming ledger, decay and the observation
clock), routes and route earning against the real `route-corpus.json`, recall against the real
`misfire-corpus.json` and its human table, the in-memory store's serialization, and the
`BrainMemory` seam end to end. `FileKnowledgeTests` (7) proves the file adapter at its boundary:
round-trip, write-behind and scheduled flush, two hundred concurrent increments, daily backups with
pruning, and quarantine with restore. The other adapters are proven at their framework boundary on a
Mac.

## Not here yet, in porting order

1. `Scrolling`: the scroll and reach machinery, over `Actuating` and `SceneProviding`; reach reads
   `UIBrain.revealers` so a name behind a dropdown is never hunted by scrolling.
2. The experience and sighting stores behind `Recall.World` (the SQLite living memory), behind a
   role beside `KnowledgeStoring`; read-hit accounting with them.
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
