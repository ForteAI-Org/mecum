import CoreGraphics

/// Per-tile identity of a frame: the frame cut into `tile`×`tile` squares (the last column/row may be
/// smaller), each hashed (FNV-1a over its normalized RGBA bytes). Two grids of the same geometry can be
/// diffed into the set of tiles whose pixels changed — the basis for re-reading only what changed.
public struct TileGrid: Sendable, Equatable {
    public let width: Int, height: Int, tile: Int
    public let cols: Int, rows: Int
    public let hashes: [UInt64]
    public init(width: Int, height: Int, tile: Int, cols: Int, rows: Int, hashes: [UInt64]) {
        self.width = width; self.height = height; self.tile = tile; self.cols = cols; self.rows = rows; self.hashes = hashes
    }
    /// A placeholder for "no grid" (a full read that never hashed): never comparable, so the next frame reads fully.
    public static func empty(width: Int, height: Int, tile: Int = TileDiff.defaultTile) -> TileGrid {
        TileGrid(width: width, height: height, tile: tile, cols: 0, rows: 0, hashes: [])
    }
}

public enum TileDiff {
    public static let defaultTile = 128

    /// Hash every tile of `image`. nil only when CoreGraphics refuses to render it.
    public static func grid(_ image: CGImage, tile: Int = defaultTile) -> TileGrid? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, tile > 0, let rgba = ImageOps.renderRGBA(image, width: w, height: h) else { return nil }
        return grid(rgba: rgba, width: w, height: h, tile: tile)
    }

    static func grid(rgba: [UInt8], width w: Int, height h: Int, tile: Int) -> TileGrid {
        let cols = (w + tile - 1) / tile, rows = (h + tile - 1) / tile
        var hashes = [UInt64](repeating: 0, count: cols * rows)
        rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for ty in 0..<rows {
                for tx in 0..<cols {
                    let x0 = tx * tile, x1 = min(w, x0 + tile), y0 = ty * tile, y1 = min(h, y0 + tile)
                    let bytes = (x1 - x0) * 4
                    var hash: UInt64 = 0xcbf29ce484222325
                    for y in y0..<y1 {
                        let row = base + (y * w + x0) * 4
                        var i = 0
                        while i + 8 <= bytes {
                            hash = (hash ^ row.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0x100000001b3
                            i += 8
                        }
                        while i < bytes {
                            hash = (hash ^ UInt64(row.load(fromByteOffset: i, as: UInt8.self))) &* 0x100000001b3
                            i += 1
                        }
                    }
                    hashes[ty * cols + tx] = hash
                }
            }
        }
        return TileGrid(width: w, height: h, tile: tile, cols: cols, rows: rows, hashes: hashes)
    }

    /// Image-pixel rects of the tiles whose hash differs. nil when the two grids are not comparable
    /// (different frame size or tile size) — the caller must treat everything as changed.
    public static func dirtyRects(from old: TileGrid, to new: TileGrid) -> [CGRect]? {
        guard old.width == new.width, old.height == new.height, old.tile == new.tile,
              old.hashes.count == new.hashes.count else { return nil }
        var out: [CGRect] = []
        let t = new.tile
        for i in new.hashes.indices where new.hashes[i] != old.hashes[i] {
            let tx = i % new.cols, ty = i / new.cols
            out.append(CGRect(x: tx * t, y: ty * t, width: min(t, new.width - tx * t), height: min(t, new.height - ty * t)))
        }
        return out
    }

    /// Merge rects that intersect (or touch) into their unions, until no two do. Order: by (minY, minX).
    public static func coalesce(_ rects: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for r in rects where !r.isNull && !r.isEmpty {
            var merged = r, changed = true
            while changed {
                changed = false
                for i in out.indices.reversed() where out[i].insetBy(dx: -1, dy: -1).intersects(merged) {
                    merged = merged.union(out[i]); out.remove(at: i); changed = true
                }
            }
            out.append(merged)
        }
        return out.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }
}
