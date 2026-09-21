//
//  TileDiff.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics

/// TileGrid is the per-tile identity of one frame: the frame cut into `tile`x`tile` squares, the
/// last column and row possibly smaller, each square hashed with FNV-1a over its normalized RGBA
/// bytes.
///
/// Two grids of the same geometry diff into the tiles whose pixels changed, which is the whole
/// basis for reading only what moved. Equal content gives equal hashes across processes and
/// launches, the same promise `SceneToken` makes one layer up.
public struct TileGrid: Sendable, Equatable {

    public let width : Int
    public let height: Int
    public let tile  : Int
    public let cols  : Int
    public let rows  : Int
    public let hashes: [UInt64]

    public init(width: Int, height: Int, tile: Int, cols: Int, rows: Int, hashes: [UInt64]) {
        self.width  = width
        self.height = height
        self.tile   = tile
        self.cols   = cols
        self.rows   = rows
        self.hashes = hashes
    }
}

/// TileDiff hashes a frame by tiles and answers which tiles changed between two frames.
///
/// The tile is 128 pixels: small enough that a hover highlight or a tooltip dirties a few squares
/// rather than a column, large enough that the hash walk stays a handful of loads per row.
public enum TileDiff {

    public static let defaultTile = 128

    /// Hashes every tile of the image, or nil when CoreGraphics refuses to render it. A nil answer
    /// is the caller's cue to read the whole frame and retain nothing.
    public static func grid(_ image: CGImage, tile: Int = defaultTile) -> TileGrid? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, tile > 0,
              let rgba = renderRGBA(image, width: width, height: height) else { return nil }
        return grid(rgba: rgba, width: width, height: height, tile: tile)
    }

    static func grid(rgba: [UInt8], width: Int, height: Int, tile: Int) -> TileGrid {
        let cols = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        var hashes = [UInt64](repeating: 0, count: cols * rows)
        rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for tileY in 0..<rows {
                for tileX in 0..<cols {
                    let x0 = tileX * tile, x1 = min(width, x0 + tile)
                    let y0 = tileY * tile, y1 = min(height, y0 + tile)
                    let bytes = (x1 - x0) * 4
                    var hash: UInt64 = 0xcbf29ce484222325
                    for y in y0..<y1 {
                        let row = base + (y * width + x0) * 4
                        var offset = 0
                        // Eight bytes at a time while the row allows it, then the tail byte by byte.
                        while offset + 8 <= bytes {
                            hash = (hash ^ row.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) &* 0x100000001b3
                            offset += 8
                        }
                        while offset < bytes {
                            hash = (hash ^ UInt64(row.load(fromByteOffset: offset, as: UInt8.self))) &* 0x100000001b3
                            offset += 1
                        }
                    }
                    hashes[tileY * cols + tileX] = hash
                }
            }
        }
        return TileGrid(width: width, height: height, tile: tile, cols: cols, rows: rows, hashes: hashes)
    }

    /// The image-pixel rects of the tiles whose hash differs, or nil when the two grids are not
    /// comparable at all: a different frame size or a different tile size. Nil means everything
    /// changed as far as the caller is concerned.
    public static func dirtyRects(from old: TileGrid, to new: TileGrid) -> [CGRect]? {
        guard old.width == new.width, old.height == new.height, old.tile == new.tile,
              old.hashes.count == new.hashes.count else { return nil }
        var out: [CGRect] = []
        let tile = new.tile
        for index in new.hashes.indices where new.hashes[index] != old.hashes[index] {
            let tileX = index % new.cols, tileY = index / new.cols
            out.append(CGRect(
                x     : tileX * tile,
                y     : tileY * tile,
                width : min(tile, new.width - tileX * tile),
                height: min(tile, new.height - tileY * tile)
            ))
        }
        return out
    }

    /// Merges rects that intersect, or merely touch, into their unions until no two do. Ordered by
    /// top edge then left edge, so a plan built from them reads top to bottom.
    public static func coalesce(_ rects: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for rect in rects where !rect.isNull && !rect.isEmpty {
            var merged = rect, changed = true
            while changed {
                changed = false
                for index in out.indices.reversed() where out[index].insetBy(dx: -1, dy: -1).intersects(merged) {
                    merged = merged.union(out[index])
                    out.remove(at: index)
                    changed = true
                }
            }
            out.append(merged)
        }
        return out.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    /// The one normalization step: draw the image into an owned sRGB premultiplied RGBA8 buffer, so
    /// the hash is taken over a known format rather than over whatever a capture handed us.
    private static func renderRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow)   = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: byteCount)
        let rendered = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data            : bytes.baseAddress,
                width           : width,
                height          : height,
                bitsPerComponent: 8,
                bytesPerRow     : width * 4,
                space           : colorSpace,
                bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? rgba : nil
    }
}
