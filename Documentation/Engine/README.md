# Engine

For the provider/model picker, saved conversations and persistent background tool sessions,
see [CLI chat](Chat.md). Start with `mecum --chat`.

For browser sessions without profile copying, the shared browser engine and MCP server,
see [Browser automation](Browser.md).

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
A Seat scene is titled with the window server's current title of the window captured, not the
title the window was adopted with: the Seat adopts a window it follows after it opened with an
empty title, and a window renamed since its adoption keeps its new name.

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
- A learned transition keeps the verb that produced it, and an expectation for one verb reads only
  that verb's transitions, so a click, a double-click, a right-click and a `set_toggle` never set
  each other's expectations. A transition stored before verbs were kept has a `click` trigger that
  any of three verbs may have produced: it is kept and annotated as of unknown verb, never added to
  and never an expectation. A stored `rightclick` had one producer and stays the right-click's. The
  trigger is still written, so an older build reads the file. An expectation never replaces the
  verification of the effect in front of the engine.
- A route is a belief: only a proof (`RouteEarning.verdict` over the outcomes its own steps cover,
  and an answer that does not hand the work back) may create one, a contradiction demotes it, and
  demotion never erases. Steps store semantic targets, never coordinates, and never typed text.
- Recall answers `fire`, `hint` or `abstain`, and every slot it fills itself must name something
  concrete: an application the graph knows by a whole component or an end of one, or an entity
  sighted inside the targeted application. "Seen but not trusted" is narrated; "never seen" is silent.
- `KnowledgeStoring` serializes its own mutations, and a load after a mutation returns sees what
  the mutation wrote whether or not it has reached disk. No storage type appears in a public API of
  the pure module; the file adapter takes its directory, clock and diagnostics at construction.
- `set_toggle` reads the control before it clicks: the resolved element's state, else a second
  reading of the same control (accessibility under its point, then a fresh perception). A state
  that stays unreadable is refused, so nothing is clicked blind. Every reading after resolution
  goes through `ControlAttribution`: ids come from labels, so an id never identifies a control
  alone; the candidate must be in the same window and section with the same id, or the same label
  and a state, and several candidates are settled only by the control's earlier place in a window
  of unchanged size. Before the click, one candidate is the control wherever it is now; after the
  click, one candidate must also be at the clicked control's place (`notAtPlace` otherwise), since a
  lone label elsewhere may be a homonym and a moved control cannot be told from one. At the place
  means over more than half of the smaller width and of the smaller height, so the next strip's
  homonym grazing the control's edge is not it, and the requested state never chooses among
  candidates. The click and
  every later reading use the control as last attributed, with that perception's geometry. Every
  outcome after resolution carries `ToggleEvidence`: the requested state, the states before and
  after with where each was read, and whether a click was sent. The evidence of a toggle or a click
  keeps the control's scene section and its container, the panel the scene shows in braces, as
  observed; it never copies the request's words. Admission accepts a section the call named only
  when it names one of those two, by the rule the resolver found the control by, and the step keeps
  the observed name.
- A delivered `click`, `double_click` or `right_click` carries `ClickEvidence`: the gesture, how it
  was delivered, and the one effect `ClickAttribution` credits it with. A menu is a pop-up window not
  listed before the gesture, the only new surface, that opened at the target and shows readable
  items; a window is a window not listed before, the only new surface, with a title, and the one
  perceived afterwards, so origin and destination are linked. Both come from the window listings
  before and after the gesture: when either cannot be taken nothing is attributed (`noCensus`), and
  when the listing before answers without the window the gesture was sent in, empty included,
  nothing is either (`originNotListed`), since that window would otherwise look new. A new window
  with the origin's title while the origin is gone is the origin re-created (`originRecreated`). A
  menu's items must come from a capture taken while its pop-up was listed, bracketed by listings on
  both sides, and of the menu rather than of the window clicked in alone (`menuNotCaptured`); in a
  capture of the window and its pop-ups together, as the Seat takes one, only the elements lying
  mostly inside the new pop-up's frame are its items, so the window's controls and the target the
  menu opened at never are, and a menu with fewer than two such rows is `unreadableSurface`. The
  evidence keeps every row that reads a letter or a digit, with no cap on their number or length;
  only the outcome's sentence names a few. A
  surface is credited only when the scenes verified the gesture (`found_acted`); otherwise it is
  `outcomeUnverified`. Anything else, a `found_acted` over a scene that merely changed included, is
  `unattributed` with its reason. A double-click is one
  gesture of two clicks, and a right-click is never replaced by a press action.
- A `select` is verified only by `DropdownReadback`, the value read at the control's place after
  the menu closed, in the full window scene or in a recognition of the control's bounds alone. At
  the place means over more than half of the smaller width and height, so the next dropdown grazing
  the control's edge is not read as its value when the control itself is not perceived. A
  value is attributed only when every element read there reads that one value in one place: an
  unlabelled chevron or a second detection of the same label does not make it uncertain, while two
  different values, or one value in two places, do. The requested item is never preferred among
  readings, and a label recalled from memory is not a reading. Text read in the pixels reads its
  label; an element described by the application's accessibility tree reads its value, since its
  label names the control ("stile") and its value is what it shows ("Regolare"), and it must agree
  with the text painted at the same place. In chat the selector perceives the window before and
  after with that tree, as chat scenes are, and the menu in pixels alone. The evidence keeps the
  control's label and the value it showed before, both as read; a call and a request may name the
  dropdown by either, and the step keeps the label.
- The living memory learns at most one verified step per turn: one `select` whose readback shows
  the requested item after another value, under a request for exactly that selection
  (`SelectionGoal`); one `set_toggle` whose evidence shows the other definite state before, a
  click, and the requested state after, under a request that asks for exactly that state
  (`ToggleGoal`); or one click, double-click or right-click whose evidence attributes a menu or a
  window to it, under a request for exactly that gesture on that target and, when it names one,
  that surface (`ClickGoal`). No goal admits a
  negation, an alternative or a second action in the step's clause, and a second step clause,
  after a comma or a sequencing word, makes the goal compound; a negation in a verifying or guard
  clause stays that clause's. The item's or target's name, with any section the call used, must
  appear as whole words. For a toggle or a click, any other word in the step's clause beyond
  connectives and the proof's window titles makes the goal `qualified`, so a memory without a
  section is neither learned nor recalled nor confirmed for "in Track 2". For a select, every word
  of the selection clause must be the item's, the control's, the proof's window title's, a verb, an
  article, a preposition, courtesy or a dropdown noun, otherwise the request is `unexplained`: a
  select step keeps no section or application, so "della scheda Bus", "di Track 2" and "in Pro
  Tools" are not learned, and a dropdown's name counts only when it is the control's label. The
  words beside the item must not extend it ("Output Busses 2" is `qualified`); an item introduced
  by an origin ("da", "dal", "from") or a replacement ("invece di", "invece che", "al posto delle",
  "piuttosto di", "anziché", "instead of"), with at most articles, prepositions and "valore"
  between ("from the X"), or sent on by a change or setting verb to another value ("Cambia X in Y",
  "Cambia X con il valore Y", "Set X to Y"), is the value left, `itemIsOrigin`. A replacement word
  without the preposition that says which value is left is `unexplained`, and an item after a
  replacement with other words between is `uncertain`. An avoidance ("evita di", "avoid") is a
  negation. Every clause is read, so an
  unparsed opening clause never hides a later negation or second selection. Recall offers a select
  memory operationally only to a request that is its single selection; one `SelectionGoal` shows
  asks for another step gets nothing, whatever words it shares, and one that only shares the
  phrase's words (unparsed, no selection, or unexplained) is history at most (`goalNotSingle`),
  never a suggestion or a followed experience. "Stop" is a guard only as a condition ("stop if"),
  so "Clicca Play e poi Stop" is two targets. A toggle already in the state is kept as no change
  and never confirms; an unreadable start or end is uncertain; the other state after the click
  contradicts only the followed experience of the same step in the same window. A turn of several
  steps is never promoted or confirmed, but it contradicts the followed experience when that one
  contradiction is every verdict about it; a verified repetition beside it, or two different
  readings, decide nothing, and the other steps' outcomes are not kept. A click without an
  attributed surface is uncertain and never contradicts. Recall offers a memory only to a request
  for its own state, or its own gesture and surface, and section, and briefs a toggle as a state to
  reach with `set_toggle` and a click as an effect to check with its own verb. Only a suggestion's
  briefing names a tool: a historical or refused briefing, for another window or application, an
  unreliable memory, a target not usable now or a request that is not the step's goal, says the
  memory authorizes nothing in that context, and a fresh observation updates it either way.
- Each kind of step the living memory learns is one `LearnableStep` in `Memory/Living`
  (`SelectionStep`, `ToggleStep`, `ClickStep`). It holds every rule of its kind: the semantic
  arguments and key it keeps, the `StepEvidence` that proves it, what a turn's call and evidence must
  show to teach it, how a request asks for it again, what a fresh scene resolves for it, and its
  briefing. `ExperienceStep` is the closed allowlist of kinds and their stored shape; `TurnAdmission`,
  `Recall` and `RecallBriefing` read a step only through the protocol, so a new kind is one conformer
  and one case. The act goals share one rule, `ActGoal`, and differ only in their
  `ActGoalVocabulary` (`ToggleGoal`, `ClickGoal`); `SelectionGoal` keeps its own reading of the item.
  All of them read the clauses and companion clauses `GoalClause` reads.
- The living memory's SQLite `user_version` also versions its JSON records. Version 2 marks toggle
  and click steps and their evidence; version 1 rows are neither rewritten nor reinterpreted, a
  select is still written in the version 1 shape, and a version 1 build refuses a version 2 file at
  open. Version 2 was never released before click records joined it, so it was extended rather
  than followed by a third version. A
  migration that changes no table is declared to read its previous version, so a read-only open,
  such as `mecum memory`, reads a version 1 file as it is; the next read-write open migrates it.

## Evidence

Unit: `ActVerificationTests` (one test per verdict), `ActOracleTests` (10: the three oracles, the exact
typed-value transition, a landed effect a contradicted oracle demotes, the unchanged no-oracle path and
the interrupted reading), `ActionPolicyTests`, `ElsewhereGuideTests`,
`PopupRowPickTests` (Premiere's measured list geometry), and `ActionEngineTests`, which drives the
whole cycle through doubles that honor the roles: resolution and its misses, the destructive gate,
dry runs, a landed click, a ghost, a repaint with a window that appeared elsewhere, expectation by
family, menu gating, activation, a dropdown opened by press, delivery failure, `set_toggle`'s
readings, attribution and homonyms, the click, double-click and right-click evidence with its window
census, the keyboard pick, type-ahead, and the pop-up dismissal. `MemoryTests` (224 tests in 20
suites) covers the knowledge containers and their legacy JSON, the brain (anchors, groups, ordinal
rescue, identity hygiene from measured Premiere failures, enrichment, the naming ledger, decay, the
observation clock and expectations per verb), routes and route earning against the real
`route-corpus.json`, recall against the real `misfire-corpus.json` and its human table, the living
memory's goals, turn admission and contextual recall for selections, toggles and clicks, the
in-memory store's serialization, and the `BrainMemory` seam end to end. `SQLiteLivingMemoryTests`
(14) proves the SQLite store: schema versions, migration, read-only opens, atomicity, idempotency and
the stored shape of its reasons. `MecumCLITests` and `ChatTests` run the chat's production path over
synthetic windows and providers (`LivingMemoryIntegrationTests`, `ToggleLivingMemoryTests`,
`ClickLivingMemoryTests`, `TurnLedgerTests`, `TurnRecorderTests`, `TurnMemoryTests`). A second
composition over the same knowledge directory stands for a restart there, inside the test process; a
real restart and real providers and applications are outside these tests. `FileKnowledgeTests` (7)
proves the file adapter at its boundary: round-trip, write-behind and scheduled flush, two hundred
concurrent increments, daily backups with pruning, and quarantine with restore. The other adapters
are proven at their framework boundary on a Mac.

## Not here yet, in porting order

1. `Scrolling`: the scroll and reach machinery, over `Actuating` and `SceneProviding`; reach reads
   `UIBrain.revealers` so a name behind a dropdown is never hunted by scrolling.
2. Read-hit accounting beside the living memory, which is now `SQLiteLivingMemory` behind
   `LivingMemoryStoring`.
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

## External local clients

The macOS app can expose its existing engine to local MCP clients. See
[Local MCP connections](LocalMCP.md) for setup, capabilities, task boundaries and cleanup.
