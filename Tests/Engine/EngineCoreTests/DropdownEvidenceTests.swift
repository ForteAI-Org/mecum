//
//  DropdownEvidenceTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import PerceptionCore
import Testing

/// Invented scenes shaped like a routing dialog: one dropdown reading "All Busses" whose menu offers
/// "Output Busses". No real application was captured.
@Suite("Dropdown selection evidence")
struct DropdownEvidenceTests {

    private let control = NormalizedRect(x: 0.40, y: 0.20, width: 0.20, height: 0.05)

    private func element(_ label: String, _ bounds: NormalizedRect) -> SceneElement {
        SceneElement(id: "control|\(label)", kind: .control, label: label, bounds: bounds)
    }

    private func scene(_ elements: [SceneElement]) -> SceneSnapshot {
        SceneSnapshot(bundleID: "test.synthetic", appName: "Synthetic Mixer", windowTitle: "Synthetic Routing",
                      viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: elements)
    }

    private func evidence(before: String = "All Busses", _ readback: DropdownReadback) -> DropdownEvidence {
        DropdownEvidence(
            bundleID          : "test.synthetic",
            windowTitle       : "Synthetic Routing",
            control           : before,
            controlRole       : "AXPopUpButton",
            section           : nil,
            valueBefore       : before,
            requestedItem     : "Output Busses",
            readback          : readback,
            menuClosedByChoice: true
        )
    }

    @Test("a value that really changed is verified evidence of a change")
    func changedValue() {
        let elsewhere = NormalizedRect(x: 0.1, y: 0.6, width: 0.1, height: 0.05)
        let after = scene([element("Output Busses", control), element("Input", elsewhere)])
        let readback = DropdownReadback.atControl(control, in: after, item: "Output Busses", windowSizeKept: true)
        #expect(readback == .window("Output Busses"))
        let outcome = ActOutcome.dropdownSelection(evidence(readback), menuWindowNumber: 4242, scene: after)
        #expect(outcome.kind == .foundActed)
        #expect(outcome.verifiedDropdown?.change == .changed)
    }

    @Test("a control that already read the item is verified but is not a change")
    func alreadySetValue() {
        let after = scene([element("Output Busses", control)])
        let readback = DropdownReadback.atControl(control, in: after, item: "Output Busses", windowSizeKept: true)
        let outcome = ActOutcome.dropdownSelection(evidence(before: "Output Busses", readback), menuWindowNumber: 4242,
                                           scene: after)
        #expect(outcome.kind == .foundActed)
        #expect(outcome.verifiedDropdown?.change == .alreadySet)
    }

    @Test("a control that still reads its old value is unverified, and says what it reads")
    func unchangedValue() {
        let after = scene([element("All Busses", control)])
        let readback = DropdownReadback.atControl(control, in: after, item: "Output Busses", windowSizeKept: true)
        #expect(readback == .window("All Busses"))
        let outcome = ActOutcome.dropdownSelection(evidence(readback), menuWindowNumber: 4242, scene: after)
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.dropdown?.change == .unverified)
        #expect(outcome.verifiedDropdown == nil)
    }

    @Test("a missing reading is unreadable with its reason, never a value")
    func missingReading() {
        let empty = scene([])
        #expect(DropdownReadback.atControl(control, in: empty, item: "Output Busses", windowSizeKept: true)
                == .unreadable(.nothingAtControl))
        let resized = scene([element("Output Busses", control)])
        #expect(DropdownReadback.atControl(control, in: resized, item: "Output Busses", windowSizeKept: false)
                == .unreadable(.windowResized))
        #expect(DropdownReadback.inCrop(nil, item: "Output Busses", windowSizeKept: true)
                == .unreadable(.cropUnavailable))
        let outcome = ActOutcome.dropdownSelection(evidence(.unreadable(.nothingAtControl)), menuWindowNumber: 4242,
                                           scene: empty)
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.verifiedDropdown == nil)
    }

    @Test("an ambiguous item is chosen from no menu and reads as no value at the control")
    func ambiguousItem() {
        // The selector chooses only an item the menu resolves uniquely; two rows of one name do not.
        let menu = scene([element("Output Busses", NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)),
                          element("Output Busses", NormalizedRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1))])
        #expect(menu.resolve(target: "Output Busses") == .ambiguous(2))
        let twoAtControl = scene([element("Input", control), element("Bus", control)])
        #expect(DropdownReadback.atControl(control, in: twoAtControl, item: "Output Busses", windowSizeKept: true)
                == .unreadable(.severalAtControl))
        #expect(DropdownReadback.inCrop(menu, item: "Output Busses", windowSizeKept: true)
                == .unreadable(.severalAtControl))
    }

    @Test("found_acted without evidence, or with unverified evidence, is not a verified selection")
    func foundActedWithoutEvidence() {
        #expect(ActOutcome(.foundActed, "synthetic selection").verifiedDropdown == nil)
        let unverified = evidence(.window("All Busses"))
        #expect(ActOutcome(.foundActed, "synthetic selection", dropdown: unverified).verifiedDropdown == nil)
    }

    @Test("a result that depends on the control crop carries that crop's reading to the caller")
    func cropEvidenceReachesTheCaller() {
        let crop = scene([element("Output Busses", NormalizedRect(x: 0, y: 0, width: 1, height: 1))])
        let readback = DropdownReadback.inCrop(crop, item: "Output Busses", windowSizeKept: true)
        #expect(readback == .controlCrop("Output Busses"))
        let fullWindow = scene([])
        let outcome = ActOutcome.dropdownSelection(evidence(readback), menuWindowNumber: 4242, scene: fullWindow)
        #expect(outcome.kind == .foundActed)
        #expect(outcome.verifiedDropdown?.readback == .controlCrop("Output Busses"))
        #expect(outcome.verifiedDropdown?.change == .changed)
        #expect(!String(describing: outcome.dropdown).contains("4242"))
    }
}
