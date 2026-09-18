# Engine

How the agent acts on what it sees. This layer opens with its contract only: the outcome vocabulary
an action answers with, the rule that decides whether an action landed, and the roles an actuator
and a scene source fill. The facilities that use them arrive module by module.

The point of the layer is the one rule it will not bend. `found_acted` requires a structural effect.
An identical scene is a ghost; a changed scene with nothing attributable is a repaint. Both answer
`acted_unverified` with a sentence that says which, because a wrong success costs more rounds than
an honest miss: it was measured as a model burning turns on a click that never happened.

## Shape

| Module | What it owns |
|---|---|
| `EngineCore` | pure types and contracts: `ActOutcome` and its closed kinds, `ActVerification`, `Actuating` with `Gesture`, `SceneProviding` with `PerceivedWindow` |

Link the `MecumEngine` library product. `EngineCore` imports `PerceptionCore`, Foundation and
CoreGraphics; no input mechanism, no window system, no model, no transport.

## Contracts

- `ActVerification.verdict` compares a remembered expectation by effect family, never by exact
  string: a flip's direction or a menu's items may vary, the kind of effect should not.
- `Actuating.perform` returns when the events have gone out and says nothing about their effect;
  the engine verifies by perceiving again. Which process, and whether delivery needs the window in
  front, is the conformer's contract: a foreground actuator posts through the HID system, a
  background one delivers to an adopted window on the Seat.
- `SceneProviding.currentScene` is a fresh perception at every call, never a cache: an action is
  resolved against this instant's positions.

## Evidence

Unit: `ActVerificationTests`, one test per verdict, plus the point mapping of `PerceivedWindow`.

## Not here yet, in porting order

1. `Engine`: the tool registry and the observe and act handlers (resolve, gesture, verify, outcome).
2. `Scrolling`: the scroll and reach machinery, over `Actuating` and `SceneProviding`.
3. `Memory`: routes, recall, the learned structure and the knowledge store, behind reading and
   writing roles the core owns; no storage type in a public API.
4. `AppAdapters`: Premiere, Pro Tools, Resolve, AppleScript, Chrome, each behind one capability
   role, so the engine never imports a bridge.
5. `HIDActuation`, the foreground `Actuating`; the Seat's background `Actuating` lives beside Driver.
6. `AgentLoop`, last, because it only orchestrates the above.

Roughly 18,700 lines of the previous engine wait behind these six; the 200 lines here are the
contract they are written against.

## Where the previous code went

| Locator | Here |
|---|---|
| `locator-mcp/Server.swift` act verification | `EngineCore/Verification/ActVerification.swift` |
