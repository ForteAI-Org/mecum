# Engine

How the agent acts on what it sees: perceive this instant, resolve a target by name, refuse what
policy refuses, deliver a gesture through a role, perceive again, and judge the effect by what
changed structurally. The layer knows which application it is driving only as a process id and a
name; it never imports an input mechanism, a window system or a model.

The point of the layer is the one rule it will not bend. `found_acted` requires a structural effect.
An identical scene is a ghost; a changed scene with nothing attributable is a repaint. Both answer
`acted_unverified` with a sentence that says which, because a wrong success costs more rounds than
an honest miss: it was measured as a model burning turns on a click that never happened.

## Shape

| Module | What it owns |
|---|---|
| `EngineCore` | pure types and contracts: `ActOutcome` and its closed kinds, `ActVerification`, `ActionVerb`, `ActionPolicy` and `ActionPermissions`, `ActivationPolicy`, `ActionTiming`, `ActionRequest`, `ElsewhereGuide`, `PopupRowPick`, and the roles `Actuating`, `SceneProviding`, `ControlPressing`, `ApplicationActivating`, `EffectExpecting`, `ActionObserving` |
| `Engine` | `ActionEngine`: the act cycle and the observe side (`describeScene`, `describeSection`, `checkGoal`) over the roles |
| `HIDActuation` | the foreground `Actuating`: synthetic events at the HID system tap |
| `AccessibilityActions` | `ControlPressing` over the live accessibility tree: open a dropdown by its own press, read a combo box's value, read a toggle under a point |
| `WorkspaceActivation` | `ApplicationActivating` over AppKit's workspace |
| `Memory` | what the agent remembers, pure: `AppKnowledge` (observed objects per window state, menu commands, the brain, routes), `UIBrain` with `ObjectAnchor`, `SiblingGroup`, `LearnedTransition`, `BrainMatcher`, `BrainUpdater` and `BrainRetention`, `Route`, `RouteEarning`, `Recall` with `RecallEvidence` and `SightingGraph`, `Allowlist`, `KnowledgeCoding`, the role `KnowledgeStoring` with `InMemoryKnowledgeStore`, and `BrainMemory`, which fills `EffectExpecting` and `ActionObserving` from the brain |
| `FileKnowledge` | `KnowledgeStoring` over one JSON file per application: write-behind, a directory lock, daily backups, quarantine and restore; and `FileAllowlistStore` |

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

## Contracts

- `ActVerification.verdict` compares a remembered expectation by effect family, never by exact
  string: a flip's direction or a menu's items may vary, the kind of effect should not.
- `Actuating.perform` returns when the events have gone out and says nothing about their effect;
  the engine verifies by perceiving again. Which process, and whether delivery needs the window in
  front, is the conformer's contract: a foreground actuator posts through the HID system, a
  background one delivers to an adopted window on the Seat.
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

Unit: `ActVerificationTests` (one test per verdict), `ActionPolicyTests`, `ElsewhereGuideTests`,
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
3. The tool registry: the names, schemas and argument parsing a model host sees, over `ActionEngine`.
4. `AppAdapters`: Premiere, Pro Tools, Resolve, AppleScript, Chrome, each behind one capability
   role, so the engine never imports a bridge.
5. The Seat's background `Actuating` and `ControlPressing`, beside Driver in the main repository.
6. `AgentLoop`, last, because it only orchestrates the above.

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
