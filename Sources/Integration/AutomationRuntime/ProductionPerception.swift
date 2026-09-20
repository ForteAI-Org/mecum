import AccessibilityFacts
import EngineCore
import Foundation
import LiveScenes
import Perception
import PixelSections
import PixelRegions
import ScreenCapture
import VisionText
import WindowServerListing

/// ProductionPerception composes the same observation adapters for actions and visual inspection.
/// It creates no memory store, actuator, provider connection, or background seat.
public enum ProductionPerception {

    /// Creates a fresh pipeline with local OCR, icon and media geometry, panels and native facts.
    public static func pipeline() -> ScenePipeline {
        ScenePipeline(text: VisionTextRecognizer(), regions: ConnectedComponentSegmenter(),
                      regionFilter: MediaRegionFilter(), sections: ColorSectionDetector(),
                      augmentation: AccessibilityAugmenter())
    }

    /// Creates a foreground reader over the production observation adapters.
    public static func foregroundScenes() -> any SceneProviding {
        LiveSceneProvider(
            pipeline: pipeline(),
            windows: WindowServerWindowListing(),
            capturer: StillCapturer(),
            identity: { RunningApplicationLookup.identity(of: $0) }
        )
    }
}
