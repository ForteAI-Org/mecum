//
//  WindowRowTitleTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import CoreGraphics
@testable import PerceptionCore
import Testing

/// Pro Tools, 28/09/2026: a double-click opened the rename window "Track 2"; the Seat followed it with the
/// empty title it adopts followed windows with, and the click was credited with no window.
@Suite("Window title of a scene")
struct WindowRowTitleTests {

    private let frame = CGRect(x: 2613, y: 1562, width: 357, height: 281)

    @Test("a scene is named by the window server's title of its window, not the one it was adopted with")
    func windowServerTitleWins() {
        let rows = [WindowRow(layer: 0, frame: frame, title: "Track 2", number: 8915),
                    WindowRow(layer: 0, frame: frame, title: "Mix: Mecum Memory QA", number: 7243)]
        #expect(WindowRow.title(ofWindow: 8915, in: rows, fallback: "") == "Track 2")
        #expect(WindowRow.title(ofWindow: 7243, in: rows, fallback: "Mix: Old Name") == "Mix: Mecum Memory QA")
    }

    @Test("without a titled row for the window, the adopted title stands")
    func fallbackWithoutATitledRow() {
        let untitled = [WindowRow(layer: 0, frame: frame, title: nil, number: 8915),
                        WindowRow(layer: 0, frame: frame, title: "  ", number: 7243)]
        #expect(WindowRow.title(ofWindow: 8915, in: untitled, fallback: "Mix") == "Mix")
        #expect(WindowRow.title(ofWindow: 7243, in: untitled, fallback: "Mix") == "Mix")
        #expect(WindowRow.title(ofWindow: 1, in: untitled, fallback: "") == "")
    }
}
