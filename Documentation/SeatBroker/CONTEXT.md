# SeatBroker context

`SeatBroker` is the reusable application-facing runtime, under
`Sources/SeatBroker` with its tests under `Tests/SeatBrokerTests`. It turns a
captured scene into `SemanticAction` values, asks Mecum to execute each action,
and verifies the resulting scene.

It perceives through the Perception layer (`MecumPerception`, described in
`Documentation/Perception/README.md`) and through nothing else. One
`ScenePipeline` is composed in `SeatBroker.init` over that layer's adapters:
`VisionTextRecognizer` for text, `ConnectedComponentSegmenter` with
`MediaRegionFilter` for regions, `ColorSectionDetector` for panels, and
`AccessibilityAugmenter` under a 0.35 s budget as the stage that only ever
adds. The pipeline never captures: the frame is the seat's own
`SeatObservationDelivery`, and the `ScenePipeline.Window` it is perceived
against carries the window server's frame from the seat's
`WindowGeometryObservation`, never an accessibility one. `SceneMapper` numbers
the resulting `SceneSnapshot` from one, which is the index a `SemanticAction`
names and `ActionExecutor` aims the command at.

Verification is the Engine's and no longer this lab's. `ActOracle.of` derives
the oracle from the action and from the surface the Command was aimed at,
before the first event goes out: a `type` into an accessibility field is held
to that field's own value, a click on a stateful control to its state, and
everything else to the closure of the surface, read from the window server by
identity. `ActVerification` consults that oracle before its scene difference,
and `OutcomeVerifier` is what is left here: the two measurements the Engine
does not carry (the encoded `SceneDifference` and the mean pixel delta) and the
mapping onto `ActionOutcome`, whose `symbol` and `sentence` the Lab shows. An
action with no oracle, a scroll or most chords, reaches `sceneChanged` and no
higher: a scene that changed is a measurement, never a verification, and this
lab does not promote one even where the two-scene rule alone would. A Command
that went out and whose after-frame could not be read keeps its verified effect
when the surface's own identity still proves it, and is `interruptedAfterPost`
otherwise, which nothing repeats.

The Lab's own locator modules are gone. What they did better lives on in the
Perception layer as roles (`ControlStateReading`, `PopupRowReading`,
`IncrementalText`) and in the Engine's `ActOracle`; the rest the layer already
covered. Scrolling an element into view has no planner any more: `ActionEngine`
has no scroll verb and this runtime posts a plain scroll through the seat, so a
scroll role is written when a consumer asks for one.

Brokering a seat is all it does: it names no lease, scheduler, or other
ownership model of its own. Those responsibilities already have precise owners
in the driver:

- `SeatHost` owns the virtual display and cursor fence.
- `AgentSeat` owns an assignment, its adopted windows, recovery, and
  restitution.
- `Turn` is the driver's bounded exclusive use of an existing assignment. It
  is deliberately not called a lease.

`AgentSession` is an application-lifecycle facade. It records provenance and
uses an existing `AgentSeat`; it does not arbitrate between applications or
hold display authority.

The SwiftUI Lab is a direct consumer of the `SeatBroker` package
product. Its app target owns chat presentation, preferences, keychain access,
and view state. It does not duplicate runtime or perception code.

## Product boundary

```mermaid
flowchart LR
    Lab[AgentLab SwiftUI] --> Broker[SeatBroker]
    Broker -->|ScenePipeline| Perception[MecumPerception]
    Broker --> Driver[MecumDriver]
    Driver --> Seat[SeatHost and AgentSeat]
    Seat -->|frames| Broker
    Locator[Lab locator targets: unused leftovers, deleted next ticket]
```

A semantic click may carry a bounded `count`. The parser accepts `/click N`
for one click and `/click N C` for `C` complete clicks, where `C` is within
`InputCommand.maximumClickCount`. The driver remains the sole authority that
constructs the individual input events and rejects invalid input counts.
