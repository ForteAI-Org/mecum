import CoreGraphics
import PerceptionCore

/// ConnectedComponentSegmenter finds non-text visual candidates using grayscale edges.
///
/// The adapter depends only on local pixels, CoreGraphics, and Accelerate. It does not infer icon
/// names, roles, or actionability. Each synchronous call owns its scratch buffers and retains no
/// image. Output rectangles use the input image's pixels and deterministic component order.
public struct ConnectedComponentSegmenter: RegionSegmenting {
    /// Failure distinguishes rejected image dimensions from a failed pixel-format conversion.
    public enum Failure: Error {
        case imageTooLarge
        case imageRenderingFailed
    }

    /// Creates the grayscale segmenter with Locator's validated control-detection thresholds.
    public init() {}

    public func segments(in image: CGImage) throws -> [CGRect] {
        let width = image.width
        let height = image.height
        guard width >= 3, height >= 3 else { return [] }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= Int(Int32.max) else { throw Failure.imageTooLarge }
        guard let grayscale = ImageOps.grayscale(image) else { throw Failure.imageRenderingFailed }

        let edges = ImageOps.sobelMagnitude(grayscale)
        let maximum = edges.pixels.max() ?? 0
        guard maximum > 0 else { return [] }
        let mask = edges.pixels.map { $0 / maximum * 255 >= 40 }
        let connected = ImageOps.dilate(mask, width: width, height: height, radius: 2)
        let maximumArea = 0.4 * Double(pixelCount)
        var kept: [Box] = []
        var oversized: [Box] = []
        for box in label(connected, width: width, height: height) where passesMinimumSize(box) {
            if Double(box.width * box.height) <= maximumArea {
                kept.append(box)
            } else {
                oversized.append(box)
            }
        }

        // Dilation can join controls to a window border. Revisit only discarded large components
        // without dilation, preserving thin strokes elsewhere and avoiding recursive rescue.
        for blob in oversized {
            let original = subMask(mask, width: width, box: blob)
            for local in label(original, width: blob.width, height: blob.height) {
                let box = Box(
                    minX: local.minX + blob.minX,
                    minY: local.minY + blob.minY,
                    width: local.width,
                    height: local.height
                )
                guard passesMinimumSize(box), Double(box.width * box.height) <= maximumArea else { continue }
                let alreadyKept = kept.contains { existing in
                    let overlapWidth = max(0, min(existing.minX + existing.width, box.minX + box.width)
                        - max(existing.minX, box.minX))
                    let overlapHeight = max(0, min(existing.minY + existing.height, box.minY + box.height)
                        - max(existing.minY, box.minY))
                    return Double(overlapWidth * overlapHeight)
                        > 0.5 * Double(min(existing.width * existing.height, box.width * box.height))
                }
                if !alreadyKept { kept.append(box) }
            }
        }

        return kept.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
    }

    private typealias Box = (minX: Int, minY: Int, width: Int, height: Int)

    private func passesMinimumSize(_ box: Box) -> Bool {
        box.width * box.height >= 150 && box.width >= 6 && box.height >= 6
    }

    private func subMask(_ mask: [Bool], width: Int, box: Box) -> [Bool] {
        var result = [Bool](repeating: false, count: box.width * box.height)
        for y in 0..<box.height {
            for x in 0..<box.width {
                result[y * box.width + x] = mask[(box.minY + y) * width + box.minX + x]
            }
        }
        return result
    }

    /// Labels eight-connected pixels in two passes, emitting roots in their discovery order.
    private func label(_ mask: [Bool], width: Int, height: Int) -> [Box] {
        var labels = [Int32](repeating: 0, count: width * height)
        var components = UnionFind()
        var count = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let index = row + x
                guard mask[index] else { continue }
                let left: Int32 = x > 0 ? labels[index - 1] : 0
                let up: Int32 = y > 0 ? labels[index - width] : 0
                let upperLeft: Int32 = x > 0 && y > 0 ? labels[index - width - 1] : 0
                let upperRight: Int32 = x < width - 1 && y > 0 ? labels[index - width + 1] : 0
                var minimum = Int32.max
                if left != 0 { minimum = min(minimum, left) }
                if up != 0 { minimum = min(minimum, up) }
                if upperLeft != 0 { minimum = min(minimum, upperLeft) }
                if upperRight != 0 { minimum = min(minimum, upperRight) }
                if minimum == Int32.max {
                    labels[index] = Int32(components.makeSet() + 1)
                    count += 1
                } else {
                    labels[index] = minimum
                    if left != 0, left != minimum { components.union(Int(minimum) - 1, Int(left) - 1) }
                    if up != 0, up != minimum { components.union(Int(minimum) - 1, Int(up) - 1) }
                    if upperLeft != 0, upperLeft != minimum {
                        components.union(Int(minimum) - 1, Int(upperLeft) - 1)
                    }
                    if upperRight != 0, upperRight != minimum {
                        components.union(Int(minimum) - 1, Int(upperRight) - 1)
                    }
                }
            }
        }

        var minimumX = [Int](repeating: Int.max, count: count)
        var minimumY = minimumX
        var maximumX = [Int](repeating: -1, count: count)
        var maximumY = maximumX
        for y in 0..<height {
            for x in 0..<width {
                let identifier = labels[y * width + x]
                guard identifier != 0 else { continue }
                let root = components.find(Int(identifier) - 1)
                minimumX[root] = min(minimumX[root], x)
                maximumX[root] = max(maximumX[root], x)
                minimumY[root] = min(minimumY[root], y)
                maximumY[root] = max(maximumY[root], y)
            }
        }
        return (0..<count).compactMap { root in
            guard maximumX[root] >= 0 else { return nil }
            return Box(
                minX: minimumX[root],
                minY: minimumY[root],
                width: maximumX[root] - minimumX[root] + 1,
                height: maximumY[root] - minimumY[root] + 1
            )
        }
    }
}
