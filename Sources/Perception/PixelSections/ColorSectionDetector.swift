import CoreGraphics
import PerceptionCore

/// ColorSectionDetector partitions a window along sustained, locally flat RGB boundaries.
/// Equal-luminance colors remain distinguishable. Text, repeated table rows and channel strips
/// do not individually become panels. The adapter creates no controls or inferred states.
///
/// Analysis uses at most 1200 pixels per side and four partition levels. It requires support
/// along most of a proposed seam; unsupported or texture-filled layouts remain unsectioned.
public struct ColorSectionDetector: SectionDetecting {
    public init() {}

    public func sections(in image: CGImage, protecting text: [CGRect] = []) throws -> [CGRect] {
        let grid = try ColorGrid(image)
        guard grid.width >= 64, grid.height >= 64 else { return [] }
        let root = Tile(x: 0, y: 0, width: grid.width, height: grid.height)
        let sx = CGFloat(image.width) / CGFloat(grid.width)
        let sy = CGFloat(image.height) / CGFloat(grid.height)
        let protected = text.filter { $0.width >= 2 * $0.height }.map {
            CGRect(x: $0.minX / sx, y: $0.minY / sy, width: $0.width / sx, height: $0.height / sy)
        }
        var leaves: [Tile] = []
        partition(root, grid: grid, protected: protected, depth: 0, into: &leaves)
        guard leaves.count > 1 else { return [] }
        return leaves.map {
            CGRect(x: CGFloat($0.x) * sx, y: CGFloat($0.y) * sy,
                   width: CGFloat($0.width) * sx, height: CGFloat($0.height) * sy)
        }
    }

    private struct Tile {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    private struct Seam {
        var position: Int
        var support: Double
    }

    private func partition(_ tile: Tile, grid: ColorGrid, protected: [CGRect], depth: Int, into leaves: inout [Tile]) {
        guard depth < 4, Double(tile.width) >= 0.10 * Double(grid.width),
              Double(tile.height) >= 0.12 * Double(grid.height) else {
            leaves.append(tile)
            return
        }
        let vertical = seams(tile, grid: grid, protected: protected, vertical: true)
        let horizontal = seams(tile, grid: grid, protected: protected, vertical: false,
                               edgeMargin: depth == 0 ? max(4, grid.height / 80) : nil)
        // Whole-window bars are peeled first. Body columns then preserve independent panel heights.
        let edge = horizontal.filter {
            $0.support >= 0.96 && ($0.position - tile.y < grid.height / 6
                || tile.y + tile.height - $0.position < grid.height / 10)
        }
        let useVertical: Bool
        let candidates: [Seam]
        if depth == 0, !edge.isEmpty {
            useVertical = false
            candidates = edge
        } else if !vertical.isEmpty && (depth <= 1
            || (vertical.map(\.support).max() ?? 0) >= (horizontal.map(\.support).max() ?? 0)) {
            useVertical = true
            candidates = vertical
        } else {
            useVertical = false
            candidates = horizontal
        }
        let start = useVertical ? tile.x : tile.y
        let end = start + (useVertical ? tile.width : tile.height)
        let boundaries = [start] + candidates.sorted {
            $0.support != $1.support ? $0.support > $1.support : $0.position < $1.position
        }.prefix(3).map(\.position).sorted() + [end]
        guard boundaries.count > 2 else { leaves.append(tile); return }
        for (lo, hi) in zip(boundaries, boundaries.dropFirst()) {
            let child = useVertical
                ? Tile(x: lo, y: tile.y, width: hi - lo, height: tile.height)
                : Tile(x: tile.x, y: lo, width: tile.width, height: hi - lo)
            partition(child, grid: grid, protected: protected, depth: depth + 1, into: &leaves)
        }
    }

    private func seams(_ tile: Tile, grid: ColorGrid, protected: [CGRect], vertical: Bool,
                       edgeMargin: Int? = nil) -> [Seam] {
        let start = vertical ? tile.x : tile.y
        let span = vertical ? tile.width : tile.height
        let length = vertical ? tile.height : tile.width
        let alongStart = vertical ? tile.y : tile.x
        let minimum = edgeMargin ?? max(12, (vertical ? grid.width : grid.height) / 24)
        guard span > 2 * minimum, length >= 8 else { return [] }
        var found: [Seam] = []
        var pattern: [Seam] = []
        let sampleCount = length - 2
        var minimumSupport = Int(Double(sampleCount) * 0.70)
        while Double(minimumSupport) / Double(sampleCount) < 0.70 { minimumSupport += 1 }
        func append(_ seam: Seam, to seams: inout [Seam]) {
            if let last = seams.last, seam.position - last.position < 4 {
                if seam.support > last.support { seams[seams.count - 1] = seam }
            } else { seams.append(seam) }
        }
        for position in (start + minimum)..<(start + span - minimum) {
            var support = 0
            var consecutive = 0
            var longest = 0
            for offset in 1..<(length - 1) {
                let along = alongStart + offset
                let x = vertical ? position : along
                let y = vertical ? along : position
                let before = grid.color(x: x - (vertical ? 1 : 0), y: y - (vertical ? 0 : 1))
                let after = grid.color(x: x, y: y)
                var qualifies = false
                if ColorGrid.distance(before, after) >= 8 {
                    let beforeAlong = grid.color(x: x - 1, y: y - 1)
                    let afterAlong = grid.color(x: x - (vertical ? 0 : 1), y: y - (vertical ? 1 : 0))
                    if ColorGrid.distance(before, beforeAlong) <= 12,
                       ColorGrid.distance(after, afterAlong) <= 12 {
                        let coloredStroke = (ColorGrid.isSaturated(after)
                            && ColorGrid.distance(before, grid.color(x: x + (vertical ? 2 : 0), y: y + (vertical ? 0 : 2))) <= 12)
                            || (ColorGrid.isSaturated(before)
                            && ColorGrid.distance(after, grid.color(x: x - (vertical ? 3 : 0), y: y - (vertical ? 0 : 3))) <= 12)
                        qualifies = !coloredStroke
                    }
                }
                if qualifies {
                    support += 1
                    consecutive += 1
                    longest = max(longest, consecutive)
                } else { consecutive = 0 }
                // Stop if perfect remaining samples cannot meet even the weaker pattern threshold.
                if support + sampleCount - offset < minimumSupport { break }
            }
            let fraction = Double(support) / Double(length - 2)
            if fraction >= 0.70 { append(Seam(position: position, support: fraction), to: &pattern) }
            guard fraction >= 0.94, Double(longest) / Double(length - 2) >= 0.35 else { continue }
            append(Seam(position: position, support: fraction), to: &found)
        }
        // A run of equally spaced separators is a repeated structure, not a row of separate panes.
        if pattern.count >= 4 {
            var remove = Set<Int>()
            for i in 0..<(pattern.count - 3) {
                let gaps = (i..<(i + 3)).map { Double(pattern[$0 + 1].position - pattern[$0].position) }
                let mean = gaps.reduce(0, +) / 3
                if gaps.allSatisfy({ abs($0 - mean) <= 0.18 * mean }) {
                    for j in i...(i + 3) { remove.insert(pattern[j].position) }
                }
            }
            found.removeAll { seam in remove.contains { abs($0 - seam.position) < 4 } }
        }
        // Test the full repeated pattern before spacing cuts apart; early spacing aliases dense
        // channel strips into a few apparently independent columns.
        found = found.filter { seam in
            !protected.contains { rect in
                if vertical {
                    return CGFloat(seam.position) > rect.minX && CGFloat(seam.position) < rect.maxX
                        && rect.maxY > CGFloat(tile.y) && rect.minY < CGFloat(tile.y + tile.height)
                }
                return CGFloat(seam.position) > rect.minY && CGFloat(seam.position) < rect.maxY
                    && rect.maxX > CGFloat(tile.x) && rect.minX < CGFloat(tile.x + tile.width)
            }
        }
        var spaced: [Seam] = []
        for seam in found {
            if let last = spaced.last, seam.position - last.position < minimum {
                if seam.support > last.support { spaced[spaced.count - 1] = seam }
            } else { spaced.append(seam) }
        }
        return spaced
    }
}

/// ColorGrid owns a bounded, top-left RGBA copy. Pixel access never escapes the image extent.
private struct ColorGrid {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let scale = min(1, 1200.0 / Double(max(image.width, image.height)))
        width = max(1, Int(Double(image.width) * scale))
        height = max(1, Int(Double(image.height) * scale))
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let width = width, height = height
        let succeeded = storage.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard succeeded else { throw Failure.allocationFailed }
        bytes = storage
    }

    func color(x: Int, y: Int) -> (Int, Int, Int) {
        let index = (max(0, min(height - 1, y)) * width + max(0, min(width - 1, x))) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    static func isSaturated(_ color: (Int, Int, Int)) -> Bool {
        max(color.0, color.1, color.2) - min(color.0, color.1, color.2) > 35
    }

    enum Failure: Error { case allocationFailed }
}
