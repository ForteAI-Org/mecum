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
| `WindowServerListing` | `WindowListing` over the window server's on-screen list |
| `AccessibilityFacts` | `SceneAugmenting` over the live accessibility tree, on the main actor, under a budget |
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
- `AccessibilityFrameTrust`: an accessibility frame is trusted only where it intersects the window
  the window server reports. After a window-server move an app's child frames keep the old
  position (measured twice on Premiere); the rule lives in the core so every adapter obeys it.
- `AccessibilityAugmentation` only adds. A scrolling container clips its children, so a row a
  toolkit reports at a virtual position is never emitted. A harvested element is final once placed:
  a second facet of the same control (a tab's radio button and its combo box) is skipped, never
  allowed to overwrite the first one's state. The deadline is a closure the caller supplies; the
  algorithm reads no clock.
- `ScenePipeline` reads no environment and keeps no state between calls. A nil segmenter yields a
  text-only scene; a nil augmenter leaves the scene as the pixels built it; an augmenter runs only
  when the window names its process and frame. A recognizer that cannot run fails the perception;
  an empty window is a scene with no elements.

## Failure

Pure functions do not throw; a degenerate input (empty list, zero-size rect) yields an empty or
zero result, documented per function. `WindowCoordinateContext` refuses a non-positive or
non-finite scale at construction. `WindowServerWindowListing` throws rather than answer a list it
did not read. `AccessibilityAugmenter` returns what it read when its budget runs out: fewer labels,
never wrong ones.

## Limits

`PopupRowSegmenter` caps rows at 240. The map tier shows up to 8 notable elements per section, 60
for an open menu. `AccessibilityAugmentation.Limits` defaults to depth 10, 24 tables, 400 elements.

## Evidence

Unit: 114 tests in 13 suites, pure, parallel, no permission needed. `ScenePipelineTests` drives the
roles with doubles that honor their ordering and failure semantics, the substitutability evidence
for the roles.

Boundary: `PerceptionBoundaryTests`, gated by `MECUM_LIVE_TESTS=1`, against a running Adobe
Premiere with Screen Recording and Accessibility granted. Measured 2026-09-17 on Premiere 26.3.2,
main window 1512×869 pt: 170 harvested elements in 0.07 to 0.20 s, a 189-element merged scene in
0.43 to 0.91 s including Vision at 2×. The suite is named apart from the Driver Live tier on
purpose: `make live-tests` filters on `LiveTests` and asserts a count.

## Not here yet, in porting order

Switch and checkbox state reading from pixels, taught icon labels, the learned structure that
rescues a remembered switch slot, section detection from pixels, content-region suppression,
incremental recognition. Each arrives as a role the pipeline takes at construction, never as a
default that silently succeeds. A `FrameCapturing` role the Seat's frames fill is the first place
this layer and Driver meet. Accessibility actions (pressing, selecting a menu row, the Go-to-Folder
navigator) and the off-view probe belong to the Engine layer, over an acting role.

## Where the previous code went

| Locator | Here |
|---|---|
| `LocatorCore/SceneSnapshot.swift` | `PerceptionCore/Scene/*` (typed kinds, states, bounds) |
| `LocatorCore/SceneComposer.swift` | `PerceptionCore/Composition/SceneComposer.swift` |
| `LocatorCore/SceneDiff.swift` | `PerceptionCore/Difference/*` (typed `SceneEffect`) |
| `LocatorCore/ElementGrouper.swift` | `PerceptionCore/Grouping/ElementGrouper.swift` |
| `LocatorCore/PopupRowSegmenter.swift` | `PerceptionCore/Popup/PopupRowSegmenter.swift` |
| `LocatorCore/Coordinates.swift` | `PerceptionCore/Geometry/WindowCoordinateContext.swift` |
| `LocatorCore/KnowledgeBase.swift` (`KnowledgeText`) | `PerceptionCore/Text/LabelText.swift` |
| `CaptureSupport/WindowSurfaces.swift` | `PerceptionCore/Windows/*` (no capture dependency) |
| `Relocation/AXSceneAugmentor.swift` (harvest, merge, trust) | `PerceptionCore/Accessibility/*` |
| `AXSupport/AXTreeReading.swift` | `PerceptionCore/Roles/AccessibilityTreeReading.swift` |
| `AXSupport/LiveAXReader.swift` (the reads) | `AccessibilityFacts/LiveAccessibilityReader.swift` |
| `CaptureSupport/WindowCaptureService.windowRows` | `WindowServerListing` |
| `OCRSupport/OCREngine.swift` | `VisionText` |
| `Relocation/SceneBuilder.detectLayers` (the pure part) | `Perception/ScenePipeline.assemble` |

Left behind on purpose: every `try!`, force unwrap and environment read the old files carried, and
the brain tests that rode along in `SceneDiffTests` (they test the brain, which is not ported).
