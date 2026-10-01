import AccessibilityFacts
import EngineCore
import Foundation
import LiveScenes
import Perception
import PixelSections
import PixelRegions
import ScreenCapture
import VisionText
import IncrementalText
import PerceptionCore
import WindowServerListing

/// ProductionPerception composes the same observation adapters for actions and visual inspection.
/// It creates no memory store, actuator, provider connection, or background seat.
public enum ProductionPerception {

    /// Creates a pipeline with scoped incremental OCR and fresh native facts on every observation.
    /// The injected text adapter supplies full or cropped reads; this pipeline owns its retained OCR.
    public static func pipeline(text: any TextRecognizing = VisionTextRecognizer()) -> ScenePipeline {
        ScenePipeline(text: IncrementalTextRecognizer(inner: text), regions: ConnectedComponentSegmenter(),
                      regionFilter: MediaRegionFilter(), sections: ColorSectionDetector(),
                      augmentation: AccessibilityAugmenter())
    }

    /// Creates a foreground reader. Excluded processes remain absent from popup-region captures,
    /// allowing an inspection overlay to observe without reading its own rendered boxes.
    public static func foregroundScenes(excludingProcesses: [pid_t] = []) -> any SceneProviding {
        LiveSceneProvider(
            pipeline: pipeline(),
            windows: WindowServerWindowListing(),
            capturer: StillCapturer(excludingProcesses: excludingProcesses),
            identity: { RunningApplicationLookup.identity(of: $0) }
        )
    }
}
