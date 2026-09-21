import AXSupport
import CoreGraphics
import CVBackend
import Foundation
import LocatorCore
import OCRSupport
import Relocation

/// A Locator scene plus what the next perception pass reuses from it.
struct PerceivedScene: Sendable {
    let snapshot: SceneSnapshot
    let ocrFrame: OCRFrame
    var timing = PerceptionTiming()
    /// Process-stable fingerprint of the element set.
    var token: String { snapshot.token }
}

/// CGImage is immutable; the box lets one cross an isolation boundary.
struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

/// The only place that composes the Locator engine: OCR, CV and surface
/// analysis in parallel on the captured frame, AX read on the main actor and
/// merged in, then sections and scene assembly. It never captures: the frame
/// comes from the seat driver. Order mirrors forte_locator's own builder.
struct LocatorPerceptionAdapter: Sendable {
    private let builder: SceneBuilder
    private let memory: LocatorMemory

    init(storeDirectory: URL) {
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        builder = SceneBuilder(icons: IconStore(directory: storeDirectory.appendingPathComponent("icons")),
                               knowledge: KnowledgeStore(directory: storeDirectory.appendingPathComponent("knowledge")),
                               learns: false)
        // Never `.shared`: that one opens and migrates a database under ~/Library/Application Support/Locator.
        memory = LocatorMemory(directory: storeDirectory.appendingPathComponent("memory"), countReads: false)
    }

    /// `windowFrame` is the adopted window's frame in global top-left points;
    /// AX geometry is normalized against it and must describe the same window
    /// the image shows.
    @concurrent
    func perceive(image boxed: ImageBox, pid: pid_t, bundleID: String, appName: String,
                  windowTitle: String, windowFrame: CGRect, previous: PerceivedScene?) async -> PerceivedScene {
        let image = boxed.image
        let pixelSize = CGSize(width: image.width, height: image.height)
        var timing = PerceptionTiming()
        let clock = ContinuousClock()

        var start = clock.now
        let layers = builder.detectLayers(in: image, appIcons: nil, brain: nil, previousOCR: previous?.ocrFrame)
        var elements = SceneBuilder.makeElements(layers.elements, pixelSize: pixelSize)
        timing.detection = start.duration(to: clock.now)

        // Electron trees are deep and slow to walk; the budget is the ceiling
        // on what AX may add, not a target. 0.35 s keeps a scene under a second.
        start = clock.now
        let ax = await MainActor.run {
            AXSceneAugmentor.tableElements(pid: pid, windowFrame: windowFrame, budgetSeconds: 0.35)
        }
        if !ax.isEmpty { elements = AXSceneAugmentor.merge(cv: elements, ax: ax) }
        timing.accessibility = start.duration(to: clock.now)

        start = clock.now
        let sectionRects = SectionDetector.detect(in: image, excluding: layers.contentRegions)
            .map { SceneBuilder.norm($0, pixelSize) }
        var (sectioned, sections) = SceneComposer.compose(elements: elements, sectionRects: sectionRects)
        SceneBuilder.annotateScrollability(sections: &sections, elements: sectioned, app: bundleID,
                                           consultMemory: false, memory: memory)
        sectioned = SceneComposer.coalesceParagraphs(sectioned)

        let snapshot = SceneSnapshot(bundleID: bundleID, app: appName, windowTitle: windowTitle,
                                     viewportPx: [image.width, image.height], elements: sectioned,
                                     sections: sections, commands: [])
        timing.composition = start.duration(to: clock.now)
        return PerceivedScene(snapshot: snapshot, ocrFrame: layers.ocrFrame, timing: timing)
    }

    /// Locator's damped scene diff: nil when nothing it trusts changed.
    static func effect(before: PerceivedScene, after: PerceivedScene, targetID: String?) -> String? {
        SceneDiff.effect(before: before.snapshot, after: after.snapshot, targetID: targetID, point: nil)
    }
}
