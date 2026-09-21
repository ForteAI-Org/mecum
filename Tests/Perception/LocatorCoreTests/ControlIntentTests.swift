import XCTest
@testable import LocatorCore

final class ControlIntentTests: XCTestCase {
    // Idempotent activation: a stateful control clicks ONLY when the live state differs from the desired
    // end-state; no-ops when already there; SKIPS when unreadable (never guess-flip a stateful control).
    func testStatefulIdempotentDecision() {
        let wantOn = ControlIntent(kind: .toggle, desiredState: .on)
        XCTAssertEqual(wantOn.action(givenCurrent: .off), .click)   // off → on: flip
        XCTAssertEqual(wantOn.action(givenCurrent: .on), .noop)     // already on: do nothing
        XCTAssertEqual(wantOn.action(givenCurrent: nil), .skip)     // unreadable: don't guess
        XCTAssertEqual(wantOn.action(givenCurrent: .unknown), .skip)

        let wantOff = ControlIntent(kind: .checkbox, desiredState: .off)
        XCTAssertEqual(wantOff.action(givenCurrent: .on), .click)
        XCTAssertEqual(wantOff.action(givenCurrent: .off), .noop)
    }

    func testNonStatefulOrNoTargetJustClicks() {
        // A plain button always clicks, regardless of any (irrelevant) state.
        XCTAssertEqual(ControlIntent(kind: .button, desiredState: .unknown).action(givenCurrent: .on), .click)
        XCTAssertEqual(ControlIntent(kind: .menu, desiredState: .unknown).action(givenCurrent: nil), .click)
        // A stateful control with no desired target degrades to a plain click (never skips).
        XCTAssertEqual(ControlIntent(kind: .toggle, desiredState: .unknown).action(givenCurrent: nil), .click)
    }

    func testControlRoundTripsAndIsAbsentInLegacyDescriptor() throws {
        var d = makeTestDescriptor()
        d.control = ControlIntent(kind: .checkbox, desiredState: .on)
        let back = try DescriptorStore.makeDecoder().decode(Descriptor.self, from: DescriptorStore.makeEncoder().encode(d))
        XCTAssertEqual(back.control, ControlIntent(kind: .checkbox, desiredState: .on))
        // A descriptor with no `control` (legacy) round-trips to nil — additive, back-compat.
        var plain = makeTestDescriptor(); plain.control = nil
        XCTAssertNil(try DescriptorStore.makeDecoder().decode(Descriptor.self, from: DescriptorStore.makeEncoder().encode(plain)).control)
    }

    private func makeTestDescriptor() -> Descriptor {
        Descriptor(id: UUID(), version: 1, created: Date(timeIntervalSince1970: 0), lastVerified: Date(timeIntervalSince1970: 0),
                   app: AppContext(bundleID: "com.x", windowTitlePattern: ".*", windowSizeAtCapture: .init(width: 100, height: 100), backingScale: 2),
                   ax: AXDescriptor(available: false, path: [], leafAttrs: nil),
                   visual: VisualDescriptor(cropRef: "c", cropSize: .init(width: 10, height: 10), contextCropRef: "x", contextMarginPx: 0, edgeHash: "00"),
                   text: TextDescriptor(selfText: nil), geometry: GeometryDescriptor(windowRelative: .init(x: 0.5, y: 0.5), sizePx: .zero, anchor: Anchor(type: "window_origin", offsetPx: .zero)))
    }
}
