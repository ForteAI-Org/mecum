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
| `PerceptionCore` | pure types and contracts: the scene vocabulary, grouping, composition, difference, pop-up rows, window classification, coordinate conversion, the accessibility harvest and its trust rule, and the roles every adapter fills |
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
- `WindowSurfaceClassifier` answers "is a pop-up open" and "which window do we drive" in one pass;
  a menu-layer window one row tall is a pop-up; every verdict carries the clause that decided it.
- Empty multiline editors are harvested as `AXTextArea`. Their AX identifier can supply a handle
  when title and description are absent, as in TextEdit's `First Text View`; frame trust still applies.
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
- `AccessibilityAugmentation` only adds. A scrolling container clips its children, so a row a
  toolkit reports at a virtual position is never emitted. A harvested element is final once placed:
  a second facet of the same control (a tab's radio button and its combo box) is skipped, never
  allowed to overwrite the first one's state. The deadline is a closure the caller supplies; the
  algorithm reads no clock.
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
never wrong ones.

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

Unit: 131 tests in 12 suites for `PerceptionCore` alone, pure, parallel, no permission needed.
`ScenePipelineTests` drives the roles with doubles that honor their ordering and failure semantics,
the substitutability evidence for the roles. `IncrementalTextTests` adds 15: the plan's thresholds
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
