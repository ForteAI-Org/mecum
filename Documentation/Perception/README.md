# Perception

How the agent sees a window: a text scene a language model reads instead of pixels. Pixels build
the whole scene and the engine works with no accessibility at all; accessibility only ever adds.
The layer knows nothing about who decides or how anything is clicked.

The point of the layer is what a scene cannot carry. It has no crop, no hash, no accessibility
path and no pixel field, by construction of its types, so nothing that serializes a scene can leak
an image. Positions are window-normalized hints for disambiguation and a way back to a pixel when
an action is taken, never a coordinate of their own.

## Shape

| Module | What it owns |
|---|---|
| `PerceptionCore` | pure types and contracts: the scene vocabulary, grouping, composition, difference, pop-up rows, window classification, coordinate conversion, the accessibility harvest with its trust rule and its read quality (`AccessibilityHarvest`, `CaptureQuality`, `LabelOrigin`), and the roles every adapter fills |
| `VisionText` | `TextRecognizing` over Apple Vision, tuned for UI labels |
| `IncrementalText` | `TextRecognizing` over another recognizer: tile hashes decide which lines to read again, and the runs of the frame before are kept |
| `WindowServerListing` | `WindowListing` over the window server's on-screen list |
| `AccessibilityFacts` | `SceneAugmenting` over the live accessibility tree, on the main actor, under a budget; and `PopupRowReading` over the open menu |
| `PixelControlState` | `ControlStateReading` over pixels: a switch's knob side, a checkbox or radio's mark, or nothing at all |
| `Perception` | `ScenePipeline`: roles in, a scene out |
| `ScreenCapture` | `StillCapturer`: one still of a window, or of a screen region holding a window and its pop-up, through ScreenCaptureKit; the foreground eye, where the Seat's capture is the background one |

There is no umbrella module. Link the `MecumPerception` library product; every consumer writes the
imports it uses. `PerceptionCore` imports Foundation and CoreGraphics only, reads no environment
and keeps no global; the adapters import `PerceptionCore` and their one framework.

## Using it

```swift
let pipeline = ScenePipeline(
    text        : VisionTextRecognizer(),
    regions     : nil,                        // a segmenter arrives as a later role
    augmentation: AccessibilityAugmenter()
)
let window = ScenePipeline.Window(
    bundleID : "com.adobe.PremierePro",
    appName  : "Adobe Premiere",
    title    : row.title ?? "",
    processID: processID,
    frame    : row.frame                      // the window server's frame, never an accessibility one
)
let scene = try await pipeline.perceive(image, of: window)
print(scene.mapText())                        // what the model reads
scene.resolve(target: "Export")               // .found, .ambiguous(n) or .none
```

## Contracts

- A centered label enclosed by a border of button height names that border
  before a neighboring caption. Adjacent buttons retain separate hit rectangles;
  glyph-sized components and thumbnail borders do not receive this priority.

- `SceneToken` is FNV-1a over sorted content and states: equal screens give equal tokens across
  processes and launches, and any element or state change gives a different one.
- `SceneIdentity.key` is position-free for a labeled element (`kind|normalized label`) and a coarse
  tenth-of-window cell for an unlabeled one. Two equal keys on one screen are a real collision the
  resolver settles with sections and rows, never a bug in the key.
- The JSON keys are the previous engine's (`pos`, `viewportPx`, `unlabeled`, `recalled`), so scenes
  it stored still decode. Pinned by `SceneSnapshotTests.legacyWireFormat`.
- `SceneDifference` counts only stable labels; a live measurement is not UI. `SceneEffect.encoded` is
  the sorted, count-free evidence string memory accumulates under, and it round-trips.
- `text()` prints sections, and the elements in each, in reading order: rows by vertical center within
  eight captured pixels, then left to right, an exact tie broken by the line itself. One screen renders
  one text whatever order composition and augmentation gathered it in. An open menu keeps its own
  order, and the map tier keeps its ranking.
- `SceneChanges` is the reader's update between two scenes of one window, in `text()`'s own lines:
  added elements whole, removed ones short, changed ones with their earlier values, under the section
  each is in now, plus a changed title, viewport, section list or commands. Elements match by id
  (kind and normalized label), duplicates by role and then distance, a caption regrouped into a
  control in place by label, and an unlabeled element, whose id is a grid cell, by kind within 0.02
  of the window. A new order, smaller moves, group tags and sections redrawn around an unchanged
  element are not changes: two readings of one screen differ in exactly those. Pixel seams move with
  the text that protects them, a header read differently renames a panel and renumbers every
  `region N`, and a group tag is memory's ordinal among every member it has learned. A changed id
  the model can target with is reported, and so is an element now in another section while its old
  section still stands, since a `section:` argument names it. Panel bounds within 0.02 are the same
  layout. Whether to send the update, and against which scene, is the caller's (`AutomationMCP`).
- `WindowSurfaceClassifier` answers "is a pop-up open" and "which window do we drive" in one pass;
  a menu-layer window one row tall is a pop-up; every verdict carries the clause that decided it.
- Empty multiline editors are harvested as `AXTextArea`. Their AX identifier can supply a handle
  when title and description are absent, as in TextEdit's `First Text View`; frame trust still applies.
  A text field or text area with no readable handle remains addressable by its measured role,
  using `Text field` or `Text area`. These are role handles, not inferred application labels.
  Missing values stay unavailable; a genuinely empty value stays empty. Popup buttons do not
  acquire this text-entry fallback. Existing clipping and duplicate-label rules still apply.
- Native editable values retain exact whitespace and line endings. An empty string is a known
  empty value; nil means unavailable. Native selection ranges use UTF-16 units and are exposed
  only when they fit the exact value, including a caret in empty text. Both scene tiers and broker
  observations carry this evidence. Whitespace-bearing values are escaped onto one text row.
  Within an `AXWebArea`, a range also requires positive native focus on that field. Browser AX
  can report 0..0 after blur while the DOM retains a different selection. An unfocused or
  unreadable focus therefore leaves the range unavailable, while preserving the exact value.
  Native fields outside web content retain their independently readable selection.
  Older serialized scenes omit selection and still decode. A valid selection change changes the
  scene token, so an action based on a different observed selection cannot reuse the old token.
  Two valid ranges on one uniquely identified editable field, with the same exact text, app and
  window title, yield a `textSelectionChanged` effect. Missing, invalid or duplicate facts do not
  establish that effect; its stable encoding carries no transient offsets into learned evidence.
- Native text-entry controls appear as `[field]` with their current element ID in both text tiers.
  This distinguishes an editable value from a same-name visual caption or version row. Typing
  prefers native text-entry matches for a shared label, while two fields remain ambiguous;
  explicit IDs and section filters keep their original scope. Matching multiline editors retain
  their native interactive role when upgrading pixel text. This changes no frame trust or input
  recipient requirements and does not infer a label-to-field relationship from proximity.
- Short `AXStaticText` values supplement missing OCR as read-only text. Their native value and
  trusted frame remain attached; a description such as `Edit field` does not replace the value.
  Static descendants of interactive controls are excluded. Controls take the element budget first,
  and static text uses only the remaining slots, within the same depth, deadline and clipping rules.
- `AccessibilityFrameTrust`: an accessibility frame is trusted only where it intersects the window
  the window server reports. After a window-server move an app's child frames keep the old
  position (measured twice on Premiere); the rule lives in the core so every adapter obeys it.
- Identified captures carry their Window ID into native augmentation. An identity predicate
  narrows AX candidates before the existing geometry check, so equally sized, overlapping
  windows remain distinguishable. An adapter without identity support supplies no native facts
  for an identified capture. Integration and SeatBroker provide the native ID resolver; the core
  has no Driver dependency. See [ADR 0026](../Driver/adr/Adr0026BindNativeFactsToCapturedWindow.md).
- `AccessibilityAugmentation` only adds. A scrolling container clips its children, so a row a
  toolkit reports at a virtual position is never emitted. A harvested element is final once placed:
  a second facet of the same control (a tab's radio button and its combo box) is skipped, never
  allowed to overwrite the first one's state. The deadline is a closure the caller supplies; the
  algorithm reads no clock.
  Native controls and static values also need at least two visible points on each axis after
  clipping to their container and the capture. Chrome's one-point proxies for offscreen elements
  supply neither an actionable control nor a visible value; scrolling can make them eligible.
- `AccessibilityAugmentation.harvest` answers the elements with the quality of the walk
  (`CaptureQuality`): `walkCompleted` is measured, never inferred from the element count, and the
  first limit met is `stoppedBy` (deadline, element, table or depth budget). Static text the element
  budget leaves out is a limit like any other. A row scrolled out of view, a frame the trust rule
  refuses, a sliver too thin to act on or a label outside the length bounds is filtered, not
  truncated. The window's role and subrole are read with it. `completeness` is derived: `complete`
  only for a found window and a finished, unstopped walk; a fact nobody observed stays unknown and
  never adds up to complete, and facts that contradict each other are an `inconsistency` every
  consumer refuses. `elements(...)` is the same walk without the quality.
- Each harvested `SceneElement` says where its label came from (`labelOrigin`: title, description,
  value, column, row content, or `identifier` for a text area named by its accessibility
  identifier) and, for a row of a table, list or outline and everything inside it, the structural
  path up to the collection (`collectionPath`). An element built from pixels has no origin, and
  neither has the `Text area` or `Text field` handle an unnamed editor receives: those names were
  read from nowhere. `container` keeps the full path a model addresses the element by, row name
  included; a structural signature reads `collectionPath` and never a row's name. The merge keeps
  both facts: an upgrade takes the harvested label with its origin, a matched pixel element lends
  itself the collection path and keeps no origin. The two facts are about the read, not the scene:
  they are not encoded and not in equality, hashing or the token, while `selectedRange` is in
  equality and hashing (`AccessibilityHarvestTests`).
- `SceneAugmenting` answers an `AccessibilityHarvest`, elements and quality together, because an
  empty list is also what a missing window or an absent grant produces. `ScenePipeline.capture`
  answers a `SceneCapture`, the scene with that quality; `perceive` is its scene. No augmenter, or
  a window with no process and frame to read, is an unknown read, never a complete one. The Engine
  carries the quality on `PerceivedWindow`, and the living memory stores it with each sample
  ([the memory schema](../Engine/MemorySchema.md#observation-contract-version-1)).
- `ControlStateReading` fills a gap, it never overrules. The pipeline asks it last, after the
  augmentation stage, and writes a state only onto an element that still carries none, so an
  application that answered for itself always wins. A reading no element covers is dropped rather
  than attached to the panel around it, and a reader that will not commit leaves the control silent.
- `IncrementalTextRecognizer` keeps the previous frame's tile grid and runs as its own state, behind
  a mutex, and decorates any other recognizer: the pipeline still asks one question and gets one
  answer, so the rule below stands. Every doubt reads the whole frame again, which is exactly what
  the inner recognizer alone would have answered: no previous frame, a different frame size, a
  different accuracy than the retained runs were read at, a crop the image refuses, or a plan whose
  rects are past `maxPartialArea` or `maxPartialRects`. A changed tile is grown to the whole lines it
  touches, never read as a fragment.
- `PopupRowReading` only ever adds, like every other accessibility role here. `PopupRowSegmenter`
  cuts the page that is painted; a conformer that reads the application's own tree sees the whole
  list, scrolled-out rows included, and says which of them are on screen. An application that
  exposes nothing answers an empty list, which is a real answer and the caller's cue to keep its
  pixel rows; the role does not throw, because an unreadable pop-up is the ordinary case. A row that
  is not on screen carries no frame, so nothing downstream can click a coordinate that is not there.
- `ScenePipeline` reads no environment and keeps no state between calls. A nil segmenter yields a
  text-only scene; a nil augmenter leaves the scene as the pixels built it; an augmenter runs only
  when the window names its process and frame; a nil control state reader leaves the scene exactly
  as it was before that role existed. A recognizer that cannot run fails the perception; an empty
  window is a scene with no elements.

## Failure

Pure functions do not throw; a degenerate input (empty list, zero-size rect) yields an empty or
zero result, documented per function. `WindowCoordinateContext` refuses a non-positive or
non-finite scale at construction. `WindowServerWindowListing` throws rather than answer a list it
did not read. `AccessibilityAugmenter` returns what it read when its budget runs out: fewer labels,
never wrong ones, and a quality that says the walk stopped at its deadline. Without the
Accessibility grant it answers an empty harvest whose quality says the grant was absent; a capture
whose frame matches no window of the tree answers `windowFound` false, which is not a denied grant.

## Limits

`PopupRowSegmenter` caps rows at 240. The map tier shows up to 8 notable elements per section, 60
for an open menu. `AccessibilityAugmentation.Limits` defaults to depth 16, 24 tables, 400 elements.
The depth includes renderer window containers; Chrome fields measured at depth 10 were excluded
by the previous ceiling. The deadline and element limits still bound the walk.
`PopupRowHarvest.Limits` defaults to depth 8, 8 candidate menus, 400 rows.
`IncrementalTextPlan` reads the whole frame again past 60% of its area or past 10 crops: the crops
have a measured 17 to 20 ms floor each and break even against one full read at about eight to ten,
so many scattered rects cost more than a full read while covering almost none of the frame.

## Evidence

Unit: 190 tests in 15 suites for `PerceptionCore` alone (`swift test list`, 2026-10-07), pure,
parallel, no permission needed; `AccessibilityHarvestTests` (10) pins the label origins (the
`identifier` origin and the placeholder handles with none included), the collection path of rows
and their children, the measured quality under every limit, the degenerate frame, the merge keeping
the facts and the unchanged wire format. `ScenePipelineTests` drives the roles with doubles that
honor their ordering and failure semantics, the substitutability evidence for the roles, and the
capture's quality beside the scene. `IncrementalTextTests` adds 15: the plan's thresholds
with their measured reasons, the tile grid, and a recording recognizer that proves an unchanged
frame is never read again and a changed tile costs one line's rect.

Boundary: `PerceptionBoundaryTests`, gated by `MECUM_LIVE_TESTS=1`, against a running Adobe
Premiere with Screen Recording and Accessibility granted. Measured 2026-09-17 on Premiere 26.3.2,
main window 1512×869 pt: 170 harvested elements in 0.07 to 0.20 s, a 189-element merged scene in
0.43 to 0.91 s including Vision at 2×. The suite is named apart from the Driver Live tier on
purpose: `make live-tests` filters on `LiveTests` and asserts a count.

## Not here yet, in porting order

Taught icon labels, the learned structure that rescues a remembered switch slot, section detection
from pixels, content-region suppression. Each arrives as a role the
pipeline takes at construction, never as a default that silently succeeds. Incremental recognition
is here, as a recognizer that decorates a recognizer rather than as a role of its own: what it
remembers is its business, and the pipeline's promise to keep nothing is untouched.
A `FrameCapturing` role the Seat's frames fill is the first place
this layer and Driver meet. Accessibility actions (pressing, selecting a menu row, the Go-to-Folder
navigator) and the off-view probe belong to the Engine layer, over an acting role.

## Where the previous code went

| Locator | Here |
|---|---|
| `LocatorCore/SceneSnapshot.swift` | `PerceptionCore/Scene/*` (typed kinds, states, bounds) |
| `LocatorCore/SceneComposer.swift` | `PerceptionCore/Composition/SceneComposer.swift` |
| `LocatorCore/SceneDiff.swift` | `PerceptionCore/Difference/*` (typed `SceneEffect`) |
| `LocatorCore/ElementGrouper.swift` | `PerceptionCore/Grouping/ElementGrouper.swift` |
| `CVBackend/ToggleStateReader.swift` | `PixelControlState/PixelControlStateReader.swift` |
| `LocatorCore/PopupRowSegmenter.swift` | `PerceptionCore/Popup/PopupRowSegmenter.swift` |
| `LocatorCore/Coordinates.swift` | `PerceptionCore/Geometry/WindowCoordinateContext.swift` |
| `LocatorCore/KnowledgeBase.swift` (`KnowledgeText`) | `PerceptionCore/Text/LabelText.swift` |
| `CaptureSupport/WindowSurfaces.swift` | `PerceptionCore/Windows/*` (no capture dependency) |
| `Relocation/AXSceneAugmentor.swift` (harvest, merge, trust) | `PerceptionCore/Accessibility/*` |
| `AXSupport/AXTreeReading.swift` | `PerceptionCore/Roles/AccessibilityTreeReading.swift` |
| `AXSupport/LiveAXReader.swift` (the reads) | `AccessibilityFacts/LiveAccessibilityReader.swift` |
| `Relocation/IncrementalOCR.swift` + `CVBackend/TileDiff.swift` | `IncrementalText/*` |
| `Relocation/AXPopupReader.swift` (the menu walk) | `PerceptionCore/Popup/PopupRowHarvest.swift`, `AccessibilityFacts/AccessibilityPopupReader.swift` |
| `CaptureSupport/WindowCaptureService.windowRows` | `WindowServerListing` |
| `OCRSupport/OCREngine.swift` | `VisionText` |
| `Relocation/SceneBuilder.detectLayers` (the pure part) | `Perception/ScenePipeline.assemble` |

Left behind on purpose: every `try!`, force unwrap and environment read the old files carried, and
the brain tests that rode along in `SceneDiffTests` (they test the brain, which is not ported).
From the incremental reader, the `LOCATOR_FULL_OCR` kill switch: a caller that wants a plain read
constructs a plain recognizer, and nothing in this layer reads the environment. From the popup
reader, everything that was not a row: pressing an item, matching a target against the list,
reading a selection back, and dropping the pixel copies of named rows. Those decide and verify an
act, which is the Engine's half, and the role here answers only what the menu holds.
