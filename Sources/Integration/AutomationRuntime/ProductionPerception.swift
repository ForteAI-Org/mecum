import AccessibilityFacts
import EngineCore
import Foundation
import LiveScenes
import Perception
import PixelSections
import PixelRegions
import ScreenCapture
import VisionText
import WindowPlacement
import WindowServerListing

/// ProductionPerception composes the same observation adapters for actions and visual inspection.
/// It creates no memory store, actuator, provider connection, or background seat.
public enum ProductionPerception {

    /// Creates a fresh pipeline with local OCR, icon and media geometry, panels and native facts.
    public static func pipeline() -> ScenePipeline {
        ScenePipeline(text: VisionTextRecognizer(), regions: ConnectedComponentSegmenter(),
                      regionFilter: MediaRegionFilter(), sections: ColorSectionDetector(),
                      augmentation: AccessibilityAugmenter(
                          windowNumberResolver: { WindowRelocator.windowNumber(of: $0) }
                      ))
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
