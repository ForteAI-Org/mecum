//
//  ScenePipeline.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// ScenePipeline builds a text scene from one window image: text runs from a recognizer, region
/// boxes from a segmenter, grouped into elements, composed into named panels, hashed into a token.
///
/// Every dependency arrives at construction. The pipeline reads no environment, keeps no global,
/// and remembers nothing between calls, so two pipelines never couple and a test drives one with
/// doubles. Recognition, icon segmentation and native reads run concurrently; section detection
/// then receives text bounds. CPU work runs off the caller's actor, including AppKit's main actor.
/// Accessibility is an optional augmentation stage taken at construction: pixels build the whole
/// scene, and the stage only adds. Control state reading is a second optional stage of the same
/// shape, asked last so an application that answered for itself always wins. The remaining stages
/// (taught icon labels, learned structure) are later roles, absent here on purpose rather than
/// defaulted to a silent no-op.
public struct ScenePipeline: Sendable {

    /// What the pipeline needs about the window besides its pixels.
    public struct Window: Sendable, Equatable {
        public var bundleID: String
        public var appName: String
        public var title: String
        /// Known menu paths to carry into the scene.
        public var commands: [String]
        /// Panel rectangles a section detector found, window-normalized. Empty composes no sections.
        public var sectionRects: [NormalizedRect]
        /// The window's owner and its frame in global points, needed by an augmentation stage to read
        /// the right tree and to judge its frames. Nil skips augmentation for this window.
        public var processID: pid_t?
        public var frame: CGRect?
        /// Stable WindowServer number when the capture source knows it.
        public var windowNumber: Int?

        public init(
            bundleID    : String,
            appName     : String,
            title       : String,
            commands    : [String] = [],
            sectionRects: [NormalizedRect] = [],
            processID   : pid_t? = nil,
            frame       : CGRect? = nil,
            windowNumber: Int? = nil
        ) {
            self.bundleID     = bundleID
            self.appName      = appName
            self.title        = title
            self.commands     = commands
            self.sectionRects = sectionRects
            self.processID    = processID
            self.frame        = frame
            self.windowNumber = windowNumber
        }
    }

    private let text: any TextRecognizing
    private let regions: (any RegionSegmenting)?
    private let regionFilter: (any VisualRegionFiltering)?
    private let sections: (any SectionDetecting)?
    private let augmentation: (any SceneAugmenting)?
    private let controlState: (any ControlStateReading)?
    private let accuracy: TextRecognitionAccuracy

    /// Creates a pipeline over its roles. A nil region segmenter supplies no icon candidates. A nil
    /// region filter leaves media classification to the caller; otherwise filtering receives OCR
    /// barriers before grouping. A nil section detector uses only caller-provided panels. A nil
    /// augmenter leaves the pixel scene. A nil control state reader leaves every control whose
    /// state no application reported silent, which is what the scene said before the role existed.
    public init(
        text        : any TextRecognizing,
        regions     : (any RegionSegmenting)? = nil,
        regionFilter: (any VisualRegionFiltering)? = nil,
        sections    : (any SectionDetecting)? = nil,
        augmentation: (any SceneAugmenting)? = nil,
        controlState: (any ControlStateReading)? = nil,
        accuracy    : TextRecognitionAccuracy = .accurate
    ) {
        self.text         = text
        self.regions      = regions
        self.regionFilter = regionFilter
        self.sections     = sections
        self.augmentation = augmentation
        self.controlState = controlState
        self.accuracy     = accuracy
    }

    /// Perceives one image of one window. Throws when recognition or segmentation cannot run;
    /// an empty window is a scene with no elements, not an error.
    @concurrent
    public func perceive(_ image: CGImage, of window: Window) async throws -> SceneSnapshot {
        try Task.checkCancellation()
        let text = self.text, regions = self.regions, sections = self.sections, accuracy = self.accuracy
        let scope = TextRecognitionScope(application: window.bundleID, processID: window.processID,
            windowNumber: window.windowNumber, title: window.title, frame: window.frame)
        async let recognized = text.recognizeText(in: image, accuracy: accuracy, scope: scope)
        async let segmented = regions?.segments(in: image) ?? []
        async let harvested = augmentationElements(for: window)
        let (runs, segments) = try await (recognized, segmented)
        try Task.checkCancellation()
        let visual = try regionFilter?.filter(segments, in: image, protecting: runs.map(\.pixelBox))
            ?? VisualRegions(icons: segments)
        try Task.checkCancellation()
        var composedWindow = window
        if composedWindow.sectionRects.isEmpty {
            let panels = try sections?.sections(in: image, protecting: runs.map(\.pixelBox)) ?? []
            let size = CGSize(width: image.width, height: image.height)
            composedWindow.sectionRects = panels.map { NormalizedRect(pixelBox: $0, in: size) }
        }
        let scene = Self.assemble(
            runs     : runs,
            segments : visual.icons,
            imageSize: CGSize(width: image.width, height: image.height),
            window   : composedWindow,
            images   : visual.images,
            overlays : visual.overlays
        )
        let nativeElements = try await harvested
        try Task.checkCancellation()
        let merged = Self.augmented(scene, with: nativeElements)
        guard let controlState else { return merged }
        return Self.stated(merged, from: image, segments: visual.icons, reader: controlState)
    }

    /// Asks the control state reader about every switch, checkbox and radio the grouper's candidate
    /// passes find in the same segments the scene was built from, and writes what it commits to onto
    /// the elements that still carry no state.
    ///
    /// Last on purpose, after augmentation: an element accessibility already spoke for is skipped, so
    /// pixels only ever fill a gap. A reading is claimed by the smallest stateless element it covers,
    /// and a reading no element covers is dropped rather than attached to the panel around it.
    private static func stated(
        _ scene  : SceneSnapshot,
        from image: CGImage,
        segments : [CGRect],
        reader   : any ControlStateReading
    ) -> SceneSnapshot {
        var readings: [(box: CGRect, state: ControlState)] = []
        for mark in ElementGrouper.markCandidates(segments: segments, isMarkShaped: reader.isMarkShaped) {
            guard let state = reader.state(of: ControlCandidate(box: mark, shape: .mark), in: image) else {
                continue
            }
            readings.append((mark, state))
        }
        // A confirmed mark leaves the switch pass's input: its dot would otherwise be read as a knob.
        let rest = segments.filter { segment in
            !readings.contains { $0.box.insetBy(dx: -1, dy: -1).contains(segment) }
        }
        for candidate in ElementGrouper.toggleCandidates(segments: rest, isToggleShaped: reader.isToggleShaped) {
            // Geometry that already saw which side the knob is on beats any pixel read.
            let read = candidate.inferredState ?? reader.state(
                of: ControlCandidate(box: candidate.rect, shape: .toggle, isAssumed: candidate.isAssumed),
                in: image
            )
            guard let read else { continue }
            readings.append((candidate.rect, read))
        }
        guard !readings.isEmpty else { return scene }
        let size = CGSize(width: image.width, height: image.height)
        var elements = scene.elements
        for reading in readings {
            let owner = elements.indices
                .filter { index in
                    guard elements[index].state == nil else { return false }
                    let box = elements[index].bounds.pixelBox(in: size)
                    let overlap = box.intersection(reading.box)
                    return !overlap.isNull && overlap.area >= 0.5 * min(box.area, reading.box.area)
                }
                .min { elements[$0].bounds.area < elements[$1].bounds.area }
            guard let owner else { continue }
            elements[owner].state = reading.state
        }
        return SceneSnapshot(
            bundleID         : scene.bundleID,
            appName          : scene.appName,
            windowTitle      : scene.windowTitle,
            viewportPixelSize: scene.viewportPixelSize,
            elements         : elements,
            sections         : scene.sections,
            commands         : scene.commands
        )
    }

    private func augmentationElements(for window: Window) async throws -> [SceneElement] {
        guard let augmentation, let processID = window.processID, let frame = window.frame else { return [] }
        return try await augmentation.augmentation(for: processID, windowFrame: frame)
    }

    /// Reads one region before text recognition and grouping, so nearby captions cannot become
    /// part of a control's value. Bounds are normalized to the supplied image; the result is local
    /// to the crop. Invalid or partly outside bounds return nil rather than silently clipping.
    /// Accessibility augmentation is disabled because its coordinates belong to the whole window.
    public func perceive(
        _ image: CGImage,
        inside bounds: NormalizedRect,
        of window: Window
    ) async throws -> SceneSnapshot? {
        let rect = bounds.cgRect
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect) else { return nil }
        let pixels = bounds.pixelBox(in: CGSize(width: image.width, height: image.height)).integral
        guard let crop = image.cropping(to: pixels) else { return nil }
        let local = Window(bundleID: window.bundleID, appName: window.appName, title: window.title)
        return try await perceive(crop, of: local)
    }

    /// Merges harvested elements into a pixel-built scene and recomputes the token. Pure; what
    /// `perceive` calls after the augmenter has answered.
    public static func augmented(_ scene: SceneSnapshot, with harvested: [SceneElement]) -> SceneSnapshot {
        guard !harvested.isEmpty else { return scene }
        var merged = AccessibilityAugmentation.merge(pixels: scene.elements, accessibility: harvested)
        if !scene.sections.isEmpty {
            // A harvested element takes the panel it lands in, like every other element.
            let rects = scene.sections.map(\.bounds)
            let names = scene.sections.map(\.name)
            for index in merged.indices where merged[index].section == nil {
                let center = merged[index].bounds.center
                var best: Int?
                for (rectIndex, rect) in rects.enumerated() where rect.contains(center) {
                    if let current = best, rects[current].area <= rect.area { continue }
                    best = rectIndex
                }
                if let best { merged[index].section = names[best] }
            }
        }
        return SceneSnapshot(
            bundleID         : scene.bundleID,
            appName          : scene.appName,
            windowTitle      : scene.windowTitle,
            viewportPixelSize: scene.viewportPixelSize,
            elements         : merged,
            sections         : scene.sections,
            commands         : scene.commands
        )
    }

    /// Assembles a scene from already-recognized runs and segments. Pure; what `perceive` calls after
    /// the roles have answered, and what a test can call without an image.
    public static func assemble(
        runs     : [RecognizedText],
        segments : [CGRect],
        imageSize: CGSize,
        window   : Window,
        images   : [CGRect] = [],
        overlays : [CGRect] = []
    ) -> SceneSnapshot {
        let usable = runs.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let textRuns = usable.map { ElementGrouper.TextRun(rect: $0.pixelBox, text: $0.text) }
        let ocrBoxes = usable.map(\.pixelBox)
        let lineHeight: CGFloat = {
            let heights = ocrBoxes.map(\.height).sorted()
            return heights.count >= 3 ? heights[heights.count / 2] : 0
        }()
        // An icon is at most a modest fraction of the window, unless a centered caption beneath it
        // says it is a thumbnail, which may be up to half the frame.
        let minSide = min(imageSize.width, imageSize.height)
        let iconMaxSide = 0.14 * minSide, thumbnailMaxSide = 0.5 * minSide
        var icons: [ElementGrouper.IconCandidate] = []
        for segment in segments {
            let box = segment.integral
            let side = max(box.width, box.height)
            guard box.width >= 10, box.height >= 10, box.width <= 4 * box.height,
                  box.height <= 4 * box.width,
                  side <= iconMaxSide
                      || (side <= thumbnailMaxSide && ElementGrouper.hasCaptionBelow(box, ocrBoxes: ocrBoxes)),
                  !ElementGrouper.isTextGlyph(box, ocrBoxes: ocrBoxes, lineHeight: lineHeight),
                  !ocrBoxes.contains(where: { $0.intersection(box).area >= 0.6 * box.area })
            else { continue }
            icons.append(ElementGrouper.IconCandidate(rect: box))
        }
        let grouped: [ElementGrouper.GroupedElement]
        if window.sectionRects.isEmpty {
            grouped = ElementGrouper.group(texts: textRuns, icons: icons)
        } else {
            let panels = window.sectionRects.map { $0.pixelBox(in: imageSize) }
            func panel(_ rect: CGRect) -> Int {
                panels.indices.filter { panels[$0].contains(CGPoint(x: rect.midX, y: rect.midY)) }
                    .min { panels[$0].area < panels[$1].area } ?? -1
            }
            let textsByPanel = Dictionary(grouping: textRuns) { panel($0.rect) }
            let iconsByPanel = Dictionary(grouping: icons) { panel($0.rect) }
            grouped = ([-1] + Array(panels.indices)).flatMap {
                ElementGrouper.group(texts: textsByPanel[$0] ?? [], icons: iconsByPanel[$0] ?? [])
            }
        }
        var elements = grouped.map { element -> SceneElement in
            let bounds = NormalizedRect(pixelBox: element.rect, in: imageSize)
            let label = element.isUnlabeled ? "(unlabeled)" : element.label
            return SceneElement(
                id         : SceneIdentity.key(
                    kind: element.kind, label: element.label, bounds: bounds, isUnlabeled: element.isUnlabeled
                ),
                kind       : element.kind,
                label      : label,
                bounds     : bounds,
                state      : element.state,
                isUnlabeled: element.isUnlabeled
            )
        }
        for (kind, boxes) in [(ElementKind.image, images), (.overlayCandidate, overlays)] {
            for box in boxes {
                let bounds = NormalizedRect(pixelBox: box, in: imageSize)
                let label = kind == .image ? "image" : "(unlabeled)"
                let unlabeled = kind == .overlayCandidate
                elements.append(SceneElement(
                    id: SceneIdentity.key(kind: kind, label: label, bounds: bounds, isUnlabeled: unlabeled),
                    kind: kind,
                    label: label,
                    bounds: bounds,
                    isUnlabeled: unlabeled
                ))
            }
        }
        var sections: [SceneSection] = []
        if !window.sectionRects.isEmpty {
            (elements, sections) = SceneComposer.compose(elements: elements, sectionRects: window.sectionRects)
        }
        return SceneSnapshot(
            bundleID         : window.bundleID,
            appName          : window.appName,
            windowTitle      : window.title,
            viewportPixelSize: ViewportPixelSize(width: Int(imageSize.width), height: Int(imageSize.height)),
            elements         : elements,
            sections         : sections,
            commands         : window.commands
        )
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
