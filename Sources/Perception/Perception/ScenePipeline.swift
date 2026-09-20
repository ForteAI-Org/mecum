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
/// doubles. Recognition and segmentation run concurrently; the wall time is the longer of the two.
/// Accessibility is an optional augmentation stage taken at construction: pixels build the whole
/// scene, and the stage only adds. Other optional stages (control state reading, taught icon labels,
/// learned structure) are later roles, absent here on purpose rather than defaulted to a silent no-op.
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

        public init(
            bundleID    : String,
            appName     : String,
            title       : String,
            commands    : [String] = [],
            sectionRects: [NormalizedRect] = [],
            processID   : pid_t? = nil,
            frame       : CGRect? = nil
        ) {
            self.bundleID     = bundleID
            self.appName      = appName
            self.title        = title
            self.commands     = commands
            self.sectionRects = sectionRects
            self.processID    = processID
            self.frame        = frame
        }
    }

    private let text: any TextRecognizing
    private let regions: (any RegionSegmenting)?
    private let augmentation: (any SceneAugmenting)?
    private let accuracy: TextRecognitionAccuracy

    /// Creates a pipeline over its roles. A nil segmenter produces a text-only scene; a nil augmenter
    /// leaves the scene as the pixels built it.
    public init(
        text        : any TextRecognizing,
        regions     : (any RegionSegmenting)? = nil,
        augmentation: (any SceneAugmenting)? = nil,
        accuracy    : TextRecognitionAccuracy = .accurate
    ) {
        self.text         = text
        self.regions      = regions
        self.augmentation = augmentation
        self.accuracy     = accuracy
    }

    /// Perceives one image of one window. Throws when recognition or segmentation cannot run;
    /// an empty window is a scene with no elements, not an error.
    public func perceive(_ image: CGImage, of window: Window) async throws -> SceneSnapshot {
        let text = self.text, regions = self.regions, accuracy = self.accuracy
        async let recognized: [RecognizedText] = Task {
            try text.recognizeText(in: image, accuracy: accuracy)
        }.value
        async let segmented: [CGRect] = Task { try regions?.segments(in: image) ?? [] }.value
        let (runs, segments) = try await (recognized, segmented)
        var scene = Self.assemble(
            runs     : runs,
            segments : segments,
            imageSize: CGSize(width: image.width, height: image.height),
            window   : window
        )
        if let augmentation, let processID = window.processID, let frame = window.frame {
            let harvested = try await augmentation.augmentation(for: processID, windowFrame: frame)
            scene = Self.augmented(scene, with: harvested)
        }
        return scene
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
        window   : Window
    ) -> SceneSnapshot {
        let usable = runs.filter {
            !ElementGrouper.isKnobGlyph($0.text) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            guard box.width >= 10, box.height >= 10,
                  side <= iconMaxSide
                      || (side <= thumbnailMaxSide && ElementGrouper.hasCaptionBelow(box, ocrBoxes: ocrBoxes)),
                  !ElementGrouper.isTextGlyph(box, ocrBoxes: ocrBoxes, lineHeight: lineHeight),
                  !ocrBoxes.contains(where: { $0.intersection(box).area >= 0.6 * box.area })
            else { continue }
            icons.append(ElementGrouper.IconCandidate(rect: box))
        }
        let grouped = ElementGrouper.group(texts: textRuns, icons: icons)
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
        var sections: [SceneSection] = []
        if !window.sectionRects.isEmpty {
            (elements, sections) = SceneComposer.compose(elements: elements, sectionRects: window.sectionRects)
            elements = SceneComposer.coalesceParagraphs(elements)
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
