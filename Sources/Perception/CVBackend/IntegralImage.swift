import Foundation

/// Summed-area tables for O(1) window sum and sum-of-squares — used for NCC mean/variance per window.
/// `Double` accumulators throughout to avoid catastrophic cancellation on low-variance windows.
struct IntegralImage {
    let width: Int
    let height: Int
    private let sum: [Double]      // (width+1) * (height+1)
    private let sumSq: [Double]

    init(_ g: GrayImage) {
        width = g.width
        height = g.height
        let sw = width + 1
        var s = [Double](repeating: 0, count: sw * (height + 1))
        var sq = [Double](repeating: 0, count: sw * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0, rowSq = 0.0
            for x in 0..<width {
                let v = Double(g.at(x, y))
                rowSum += v
                rowSq += v * v
                s[(y + 1) * sw + (x + 1)] = s[y * sw + (x + 1)] + rowSum
                sq[(y + 1) * sw + (x + 1)] = sq[y * sw + (x + 1)] + rowSq
            }
        }
        sum = s
        sumSq = sq
    }

    /// Sum over the `w×h` window with top-left at (x, y). Caller guarantees the window is in bounds.
    @inline(__always) func boxSum(x: Int, y: Int, w: Int, h: Int) -> Double {
        corners(sum, x: x, y: y, w: w, h: h)
    }

    @inline(__always) func boxSumSq(x: Int, y: Int, w: Int, h: Int) -> Double {
        corners(sumSq, x: x, y: y, w: w, h: h)
    }

    @inline(__always) private func corners(_ t: [Double], x: Int, y: Int, w: Int, h: Int) -> Double {
        let sw = width + 1
        let a = t[y * sw + x]
        let b = t[y * sw + (x + w)]
        let c = t[(y + h) * sw + x]
        let d = t[(y + h) * sw + (x + w)]
        return d - b - c + a
    }
}
