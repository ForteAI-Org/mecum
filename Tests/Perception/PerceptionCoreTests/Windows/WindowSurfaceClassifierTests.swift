//
//  WindowSurfaceClassifierTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import PerceptionCore
import Testing

/// One classifier answers both "is a pop-up open" and "which window do we drive", over window rows
/// measured on the machine, so the two answers can never disagree again.
@Suite("Window surface classification")
struct WindowSurfaceClassifierTests {

    private func row(_ layer: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     _ title: String? = nil, number: Int = 0) -> WindowRow {
        WindowRow(layer: layer, frame: CGRect(x: x, y: y, width: w, height: h), title: title, number: number)
    }

    /// DaVinci Resolve, Project Settings with the resolution list open: a dropdown drawn as an
    /// ordinary window over a 1040 by 736 dialog.
    private var davinciWithListOpen: [WindowRow] {
        [row(0, 676, 283, 260, 420),
         row(0, 236, 123, 1040, 736, "Project Settings: Untitled Project 1"),
         row(0, 0, 194, 1360, 714, "tracks")]
    }

    /// Premiere's AAF Export Settings on a seat with the two-row Sample Rate list open, measured
    /// with the window server on 2026-09-12: the list is 220 by 56 on layer 101.
    private var premiereWithTwoRowListOpen: [WindowRow] {
        [row(101, 2725, 1691, 220, 56, number: 6733),
         row(0, 2608, 1437, 367, 530, "AAF Export Settings", number: 6700),
         row(0, 2036, 1268, 1512, 869, "/Users/r/Documents/Adobe/Premiere Pro/26.0/my first project.prproj *")]
    }

    private var allFixtures: [(String, [WindowRow])] {
        [("davinci", davinciWithListOpen),
         ("premiere-two-row", premiereWithTwoRowListOpen),
         ("premiere-menu-layer", [row(101, 471, 298, 296, 432), row(0, 35, 34, 1058, 874, "p.prproj")]),
         ("protools-new-tracks", [row(8, 350, 400, 815, 124, "New Tracks"), row(0, 0, 100, 1500, 900, "Edit")]),
         ("submenu", [row(101, 1000, 400, 200, 300), row(101, 900, 300, 129, 197), row(0, 0, 100, 1500, 900, "Edit")]),
         ("palette", [row(3, 0, 194, 120, 714), row(0, 0, 194, 1360, 714, "tracks")]),
         ("empty", [])]
    }

    @Test("a window-layer dropdown is a pop-up and the surface")
    func windowLayerDropdown() {
        let surfaces = WindowSurfaceClassifier.classify(davinciWithListOpen)
        #expect(surfaces.popups == [CGRect(x: 676, y: 283, width: 260, height: 420)])
        #expect(surfaces.interaction?.frame == surfaces.popups.first)
        #expect(surfaces.verdicts.first?.kind == .floatingList)
    }

    @Test("a two-row menu-layer list is a pop-up")
    func twoRowMenuLayerList() {
        let surfaces = WindowSurfaceClassifier.classify(premiereWithTwoRowListOpen)
        #expect(surfaces.popups == [CGRect(x: 2725, y: 1691, width: 220, height: 56)])
        #expect(surfaces.verdicts.first?.kind == .popupLayer)
        #expect(surfaces.interaction?.frame == surfaces.popups.first)
        #expect(surfaces.hasOpenPopup)
    }

    @Test("a menu-layer sliver is chrome; the square floor still guards the window-layer guess")
    func sliverAndSquareFloor() {
        let rest = Array(premiereWithTwoRowListOpen.dropFirst())
        let sliver = WindowSurfaceClassifier.classify([row(101, 2725, 1691, 220, 12)] + rest)
        #expect(sliver.popups.isEmpty)
        #expect(sliver.verdicts.first?.kind == .chrome)
        let ordinary = WindowSurfaceClassifier.classify([row(0, 2725, 1691, 220, 56)] + rest)
        #expect(ordinary.popups.isEmpty)
        #expect(ordinary.verdicts.first?.kind != .floatingList)
    }

    @Test("the picker and the detector can never disagree")
    func neverDisagree() {
        for (name, rows) in allFixtures {
            let surfaces = WindowSurfaceClassifier.classify(rows)
            if let popup = surfaces.popups.first {
                #expect(surfaces.interaction?.frame == popup, "\(name)")
            }
        }
    }

    @Test("what must not become a pop-up")
    func notPopups() {
        let modal = [row(8, 350, 400, 815, 124, "New Tracks"), row(0, 0, 100, 1500, 900, "Edit: Session")]
        let modalSurfaces = WindowSurfaceClassifier.classify(modal)
        #expect(modalSurfaces.popups.isEmpty)
        #expect(modalSurfaces.interaction?.frame == modal[0].frame)
        #expect(WindowSurfaceClassifier.classify([row(8, 350, 400, 815, 124), row(0, 0, 100, 1500, 900, "Edit: Session")]).popups.isEmpty)
        let palette = WindowSurfaceClassifier.classify([row(3, 0, 194, 120, 714), row(0, 0, 194, 1360, 714, "tracks")])
        #expect(palette.popups.isEmpty)
        #expect(palette.verdicts.first?.kind == .window)
        #expect(WindowSurfaceClassifier.classify([row(0, 700, 300, 190, 400, "Rename"), row(0, 0, 194, 1360, 714, "tracks")]).popups.isEmpty)
        #expect(WindowSurfaceClassifier.classify([row(0, 700, 300, 190, 400)]).popups.isEmpty)
        #expect(WindowSurfaceClassifier.classify([row(0, 236, 123, 1040, 736), row(0, 0, 194, 1360, 714, "tracks")]).popups.isEmpty)
        let behind = [row(0, 0, 100, 1200, 800, "Document"), row(0, 676, 283, 190, 400), row(0, 0, 194, 1360, 714, "tracks")]
        let behindSurfaces = WindowSurfaceClassifier.classify(behind)
        #expect(behindSurfaces.popups.isEmpty)
        #expect(behindSurfaces.interaction?.frame == behind[0].frame)
    }

    @Test("unreadable titles disable the window-layer rule, and the rule can be turned off")
    func honestyGateAndKillSwitch() {
        let untitled = [row(0, 676, 283, 260, 420), row(0, 236, 123, 1040, 736), row(0, 0, 194, 1360, 714)]
        let surfaces = WindowSurfaceClassifier.classify(untitled)
        #expect(surfaces.popups.isEmpty)
        #expect(surfaces.interaction?.frame == untitled[0].frame)
        let off = WindowSurfaceClassifier.classify(davinciWithListOpen, allowFloatingLists: false)
        #expect(off.popups.isEmpty)
        #expect(off.interaction?.frame == davinciWithListOpen[0].frame)
    }

    @Test("menu-layer pop-ups, submenus and slivers")
    func menuLayer() {
        let premiere = [row(101, 471, 298, 296, 432), row(0, 35, 34, 1058, 874, "/Users/…/project.prproj")]
        let premiereSurfaces = WindowSurfaceClassifier.classify(premiere)
        #expect(premiereSurfaces.popups == [premiere[0].frame])
        #expect(premiereSurfaces.verdicts.first?.kind == .popupLayer)
        let tiny = [row(101, 900, 300, 129, 197), row(0, 0, 100, 1500, 900, "Edit: Session")]
        #expect(WindowSurfaceClassifier.classify(tiny).popups == [tiny[0].frame])
        let submenu = [row(101, 1000, 400, 200, 300), row(101, 900, 300, 129, 197), row(0, 0, 100, 1500, 900, "Edit: Session")]
        let submenuSurfaces = WindowSurfaceClassifier.classify(submenu)
        #expect(submenuSurfaces.popups.count == 2)
        #expect(submenuSurfaces.popups.first == submenu[0].frame)
        let sliver = [row(101, 900, 300, 40, 20), row(0, 0, 100, 1500, 900, "Edit: Session")]
        let sliverSurfaces = WindowSurfaceClassifier.classify(sliver)
        #expect(sliverSurfaces.popups.isEmpty)
        #expect(sliverSurfaces.interaction?.frame == sliver[1].frame)
    }

    @Test("the picker's own choices")
    func picker() {
        let modal = [row(8, 350, 400, 815, 124, "New Tracks"), row(0, 0, 100, 1500, 900, "Edit: Session")]
        #expect(WindowSurfaceClassifier.classify(modal).interaction?.frame == modal[0].frame)
        let tooltip = [row(0, 400, 400, 300, 40, "tip"), row(0, 0, 100, 1500, 900, "Edit: Session")]
        #expect(WindowSurfaceClassifier.classify(tooltip).interaction?.frame == tooltip[1].frame)
        let strip = [row(3, 0, 0, 1400, 60, "strip"), row(0, 100, 100, 300, 80, "small doc")]
        #expect(WindowSurfaceClassifier.classify(strip).interaction?.frame == strip[1].frame)
        #expect(WindowSurfaceClassifier.classify([]).interaction == nil)
        #expect(WindowSurfaceClassifier.classify([]).popups.isEmpty)
    }

    @Test("a rejection names the clause that failed; an acceptance names the parent")
    func verdictsExplain() {
        let modal = [row(8, 350, 400, 815, 124, "New Tracks"), row(0, 0, 100, 1500, 900, "Edit: Session")]
        #expect(WindowSurfaceClassifier.classify(modal).verdicts[0].why.contains("titled"))
        let untitled = WindowSurfaceClassifier.floatingList(row(8, 350, 400, 815, 124), behind: [modal[1]], titlesLegible: true)
        guard case .no(let clause) = untitled else { Issue.record("expected a rejection"); return }
        #expect(clause.contains("6.5") || clause.contains("6.6"))
        #expect(WindowSurfaceClassifier.classify(davinciWithListOpen).verdicts[0].why.contains("1040"))
    }
}
