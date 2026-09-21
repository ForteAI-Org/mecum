import XCTest
import CoreGraphics
@testable import Relocation

/// The micro-scroll probe's math, on synthetic frames: a content band that shifts between frames (a
/// scrolling pane) inside unchanging chrome. The probe watches a FIXED region and asks two things —
/// did these pixels change, and by how many rows did they slide.
final class ScrollProbeTests: XCTestCase {

    /// 800×600 gray frame: white background, a "chrome" block at the top, and a pane whose rows of
    /// APERIODIC content (like real app cards — varied heights and shades) sit shifted by `offset`.
    /// Perfectly periodic stripes would be dishonest here: they alias every estimator, and real UI
    /// content isn't periodic.
    private func frame(stripeOffset: Int, noise: Bool = false) -> CGImage {
        let w = 800, h = 600
        var buf = [UInt8](repeating: 255, count: w * h)
        for y in 0..<60 { for x in 0..<w { buf[y * w + x] = 40 } }   // fixed chrome
        // Aperiodic "cards" in the pane band y 150..<550: (start, thickness, shade) tuples.
        let rows: [(Int, Int, UInt8)] = [(0, 10, 0), (34, 22, 90), (85, 8, 30), (120, 30, 160),
                                         (170, 12, 10), (215, 26, 120), (260, 9, 60), (300, 18, 20),
                                         (340, 14, 140), (372, 24, 45)]
        for (start, thick, shade) in rows {
            for dy in 0..<thick {
                let y = 150 + start + dy + stripeOffset
                guard y >= 150, y < 550 else { continue }
                for x in 100..<700 { buf[y * w + x] = noise ? UInt8((x * 7 + y * 13) % 255) : shade }
            }
        }
        return buf.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                .makeImage()!
        }
    }

    /// The pane region of the synthetic frame, cropped the way the probe crops its watch rect.
    private func pane(_ img: CGImage) -> CGImage { img.cropping(to: CGRect(x: 100, y: 150, width: 600, height: 400))! }

    func testShiftIsMeasuredFromRowProfiles() {
        let a = pane(frame(stripeOffset: 0))
        let b = pane(frame(stripeOffset: 24))   // pane scrolled 24px; chrome identical
        let lag = ScrollProbe.profileShift(before: ScrollProbe.rowProfile(a),
                                       after: ScrollProbe.rowProfile(b), maxLag: 120)
        XCTAssertNotNil(lag, "a real shift must be measurable")
        XCTAssertEqual(Double(abs(lag ?? 0)), 24, accuracy: 8)
    }

    func testIdenticalFramesShowNoShift() {
        let a = pane(frame(stripeOffset: 0))
        XCTAssertNil(ScrollProbe.profileShift(before: ScrollProbe.rowProfile(a),
                                          after: ScrollProbe.rowProfile(a), maxLag: 120))
    }

    func testIncoherentChangeIsNotAShift() {
        // The band CHANGES (noise) but nothing slides — an animation, not a scroll.
        let a = pane(frame(stripeOffset: 0))
        let b = pane(frame(stripeOffset: 0, noise: true))
        XCTAssertNil(ScrollProbe.profileShift(before: ScrollProbe.rowProfile(a),
                                          after: ScrollProbe.rowProfile(b), maxLag: 120))
    }
}

/// WHICH WAY DID THE VIEW GO — the pixel direction witness the wheel's sign is checked against.
///
/// A NOTE ON THE SIGN, and why it is measured rather than derived: these frames are written straight
/// into a byte buffer, and a row written FURTHER DOWN the buffer comes back FURTHER UP the screen once
/// `grayPixels` has re-read the image. Verified against real captures whose direction was checked by
/// eye — a TextEdit view scrolled visibly DOWN aligns at lag −120, and this generator's
/// `viewDownBy: +40` aligns negative too. So the parameter is named for what it does to the VIEW, which
/// is the only thing a caller can act on.
final class VerticalSlideTests: XCTestCase {
    /// 800×600: fixed chrome, aperiodic "cards", the view scrolled DOWN by `viewDownBy` pixels.
    private func frame(viewDownBy: Int, noise: Bool = false) -> CGImage {
        let w = 800, h = 600
        var buf = [UInt8](repeating: 255, count: w * h)
        for y in 0..<60 { for x in 0..<w { buf[y * w + x] = 40 } }   // fixed chrome
        let rows: [(Int, Int, UInt8)] = [(0, 10, 0), (34, 22, 90), (85, 8, 30), (120, 30, 160),
                                         (170, 12, 10), (215, 26, 120), (260, 9, 60), (300, 18, 20),
                                         (340, 14, 140), (372, 24, 45)]
        for (start, thick, shade) in rows {
            for dy in 0..<thick {
                let y = 150 + start + dy + viewDownBy
                guard y >= 150, y < 550 else { continue }
                for x in 100..<700 { buf[y * w + x] = noise ? UInt8((x * 7 + y * 13) % 255) : shade }
            }
        }
        return image(buf, w, h)
    }

    /// EVENLY SPACED rows of DIFFERENT content — a text document's lines, a file list, a track list:
    /// one row every 20px, each with its own pattern of ink blocks across x. The pitch is periodic; the
    /// rows are not. This is the shape that defeats a row MEAN (measured on a real 900-line TextEdit
    /// document and a real Finder list: the mean's mirror fits within 4–34% of the winner, so its sign
    /// is a coin toss) and the reason the reading is taken on a row SIGNATURE instead.
    private func textLines(viewDownBy: Int) -> CGImage {
        let w = 800, h = 600
        var buf = [UInt8](repeating: 245, count: w * h)
        for line in 0..<40 {
            let y0 = 60 + line * 20 + viewDownBy
            guard y0 >= 60, y0 + 8 < h else { continue }
            // Each line's "words": start/length pairs derived from the line index, so no two lines put
            // their ink in the same columns.
            var x = 110 + (line * 37) % 90
            var word = 0
            while x < 700, word < 6 {
                let len = 30 + ((line * 13 + word * 29) % 70)
                for dy in 0..<8 { for xx in x..<min(700, x + len) { buf[(y0 + dy) * w + xx] = 35 } }
                x += len + 14 + ((line * 7 + word * 11) % 26)
                word += 1
            }
        }
        return image(buf, w, h)
    }

    /// Perfectly PERIODIC rows (a track list, a table of identical cells) — nothing here can name a
    /// direction, and the reading has to say so.
    private func striped(viewDownBy: Int) -> CGImage {
        let w = 800, h = 600
        var buf = [UInt8](repeating: 235, count: w * h)
        for y in 150..<550 where (y - 150 - viewDownBy + 4000) % 40 < 20 {
            for x in 100..<700 { buf[y * w + x] = 60 }
        }
        return image(buf, w, h)
    }

    private func image(_ buf: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        var buf = buf
        return buf.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                .makeImage()!
        }
    }

    private func pane(_ img: CGImage) -> CGImage { img.cropping(to: CGRect(x: 100, y: 150, width: 600, height: 400))! }

    func testAViewScrollingUpReadsPositive() {
        // The view went UP: it revealed what was above, so positive by the documented contract.
        let px = ScrollProbe.contentSlidePx(before: pane(frame(viewDownBy: 40)), after: pane(frame(viewDownBy: 0)))
        XCTAssertNotNil(px)
        XCTAssertGreaterThan(px ?? 0, 0, "a view scrolling up must read positive")
        XCTAssertEqual(Double(px ?? 0), 40, accuracy: 8)   // a 400px crop ⇒ signature rows are pane pixels
    }

    func testAViewScrollingDownReadsNegative() {
        let px = ScrollProbe.contentSlidePx(before: pane(frame(viewDownBy: 0)), after: pane(frame(viewDownBy: 40)))
        XCTAssertNotNil(px)
        XCTAssertLessThan(px ?? 0, 0, "a view scrolling down must read negative")
    }

    func testStillPaneReadsNoDirection() {
        XCTAssertNil(ScrollProbe.contentSlidePx(before: pane(frame(viewDownBy: 0)), after: pane(frame(viewDownBy: 0))))
    }

    func testIncoherentChangeIsNotADirection() {
        XCTAssertNil(ScrollProbe.contentSlidePx(before: pane(frame(viewDownBy: 0)),
                                                after: pane(frame(viewDownBy: 0, noise: true))))
    }

    func testEvenlySpacedTextLinesStillNameTheirDirection() {
        let down = ScrollProbe.contentSlidePx(before: pane(textLines(viewDownBy: 0)),
                                              after: pane(textLines(viewDownBy: 60)))
        XCTAssertNotNil(down, "an evenly spaced list of DIFFERENT rows is readable")
        XCTAssertLessThan(down ?? 0, 0)
        let up = ScrollProbe.contentSlidePx(before: pane(textLines(viewDownBy: 60)),
                                            after: pane(textLines(viewDownBy: 0)))
        XCTAssertNotNil(up)
        XCTAssertGreaterThan(up ?? 0, 0)
    }

    func testTextLinesMovedByAWholeLineStillNameTheirDirection() {
        // The nastiest alias: a slide of EXACTLY one line pitch, where every row lands where a row
        // already was. Only the per-row content can break that tie.
        let px = ScrollProbe.contentSlidePx(before: pane(textLines(viewDownBy: 0)),
                                            after: pane(textLines(viewDownBy: 20)))
        XCTAssertNotNil(px)
        XCTAssertLessThan(px ?? 0, 0)
        XCTAssertEqual(Double(px ?? 0), -20, accuracy: 6)
    }

    func testPeriodicRowsRefuseToNameADirection() {
        // Identical rows align just as well the other way: the magnitude is a guess and the SIGN is a
        // coin toss. `profileShift` happily returns one (it only asks "did it slide"); the direction
        // reading must refuse — learning a wheel sign from a coin toss inverts every later scroll.
        let a = pane(striped(viewDownBy: 0)), b = pane(striped(viewDownBy: 12))
        XCTAssertNotNil(ScrollProbe.profileShift(before: ScrollProbe.rowProfile(a),
                                                 after: ScrollProbe.rowProfile(b), maxLag: 120),
                        "the movement measurement still reads a shift here")
        XCTAssertNil(ScrollProbe.contentSlidePx(before: a, after: b))
    }
}

/// WHICH WINDOW a scroll drives. `.first` of the AX window list is not it: measured on Finder while it
/// was in the background, the first window is a 157×17pt phantom, and a burst delivered inside that
/// strip reported movement (5% of a 34px-tall crop is noise) while the real list never moved.
final class ScrollWindowPickTests: XCTestCase {
    private let real = CGRect(x: 159, y: 168, width: 920, height: 436)
    private let phantom = CGRect(x: 772, y: 375, width: 157, height: 17)   // the measured one
    private let sheet = CGRect(x: 100, y: 100, width: 815, height: 124)    // Pro Tools "New Tracks"

    func testAPhantomListedFirstDoesNotWin() {
        XCTAssertEqual(ScrollWindow.pick([phantom, real]), 1)
    }

    func testTheFrontmostSubstantialWindowWins() {
        // AX order is frontmost-first, so a real window ahead of another real window keeps its place —
        // and a short-wide sheet in front of the main window is what the user is looking at.
        XCTAssertEqual(ScrollWindow.pick([real, CGRect(x: 0, y: 0, width: 1200, height: 900)]), 0)
        XCTAssertEqual(ScrollWindow.pick([sheet, real]), 0)
    }

    func testAllPhantomsFallBackToTheLargest() {
        // Nothing substantial on offer: drive the biggest thing there is rather than refusing.
        XCTAssertEqual(ScrollWindow.pick([phantom, CGRect(x: 0, y: 0, width: 300, height: 40)]), 1)
    }

    func testDegenerateFramesAreIgnored() {
        XCTAssertEqual(ScrollWindow.pick([.zero, real]), 1)
        XCTAssertNil(ScrollWindow.pick([.zero]))
        XCTAssertNil(ScrollWindow.pick([]))
    }
}
