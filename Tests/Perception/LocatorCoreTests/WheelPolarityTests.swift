import XCTest
@testable import LocatorCore

/// THE WHEEL'S SIGN — which `wheel1` value scrolls a view UP on THIS machine, in THIS app. Natural
/// scrolling inverts it (and it is on by default), and some apps invert it internally, so the engine
/// measures the sign it gets instead of trusting a convention. These are the rules the measurement
/// feeds and the burst reads.
final class WheelPolarityTests: XCTestCase {
    private func freshMemory() -> LocatorMemory {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelpol-\(UUID().uuidString)", isDirectory: true)
        return LocatorMemory(directory: dir)
    }

    // MARK: the sign contract (pure — this is what the burst asks before it posts anything)

    func testRequestedDirectionPicksTheWheelSign() {
        // upSign −1 (this Mac, natural scrolling ON): asking for "up" posts −1, "down" posts +1.
        XCTAssertEqual(WheelPolarity.wheel1(requestedTicks: -3, upSign: -1), -3)
        XCTAssertEqual(WheelPolarity.wheel1(requestedTicks: 3, upSign: -1), 3)
        // upSign +1 (the classic convention): the same requests post the opposite lines.
        XCTAssertEqual(WheelPolarity.wheel1(requestedTicks: -3, upSign: 1), 3)
        XCTAssertEqual(WheelPolarity.wheel1(requestedTicks: 3, upSign: 1), -3)
    }

    func testWheelLinesAreClampedToASaneBurst() {
        XCTAssertEqual(WheelPolarity.wheel1(requestedTicks: 40, upSign: -1), 6)    // 6 lines per event, capped
        XCTAssertEqual(WheelPolarity.wheel1(requestedTicks: 0, upSign: -1), 1)     // never a zero-line event
    }

    func testTheMeasuredDirectionIsCheckedAgainstWhatWasAskedFor() {
        XCTAssertEqual(WheelPolarity.requestWasHonoured(requestedTicks: -3, viewWentUp: true), true)   // asked up, went up
        XCTAssertEqual(WheelPolarity.requestWasHonoured(requestedTicks: -3, viewWentUp: false), false) // asked up, went down
        XCTAssertEqual(WheelPolarity.requestWasHonoured(requestedTicks: 3, viewWentUp: false), true)   // asked down, went down
        XCTAssertEqual(WheelPolarity.requestWasHonoured(requestedTicks: 3, viewWentUp: true), false)   // asked down, went up
        XCTAssertNil(WheelPolarity.requestWasHonoured(requestedTicks: 3, viewWentUp: nil))             // unread ⇒ learn nothing
    }

    func testTheSignThatWorkedIsDerivableFromOneBurst() {
        // A burst posted with upSign −1 that went the way it was asked CONFIRMS −1; one that went the
        // other way proves +1 — whichever direction was requested.
        XCTAssertEqual(WheelPolarity.provenUpSign(postedWith: -1, requestedTicks: 3, viewWentUp: false), -1)
        XCTAssertEqual(WheelPolarity.provenUpSign(postedWith: -1, requestedTicks: 3, viewWentUp: true), 1)
        XCTAssertEqual(WheelPolarity.provenUpSign(postedWith: 1, requestedTicks: -3, viewWentUp: true), 1)
        XCTAssertEqual(WheelPolarity.provenUpSign(postedWith: 1, requestedTicks: -3, viewWentUp: false), -1)
        XCTAssertNil(WheelPolarity.provenUpSign(postedWith: 1, requestedTicks: -3, viewWentUp: nil))
    }

    // MARK: what gets remembered

    func testTheDefaultIsTheMeasuredMacNotTheTextbook() {
        // Nothing learned yet: a default Mac scrolls its view DOWN on a POSITIVE wheel1 (natural
        // scrolling is on out of the box, and it was measured on this one), so upSign is −1.
        let m = freshMemory()
        XCTAssertEqual(WheelPolarity.upSign(app: "com.apple.finder", axis: .vertical, memory: m), -1)
        XCTAssertFalse(WheelPolarity.isKnown(app: "com.apple.finder", axis: .vertical, memory: m),
                       "a default is not a measurement — the calibration nudge is still owed")
    }

    func testALearnedSignIsRemembered() {
        let m = freshMemory()
        WheelPolarity.learn(app: "com.apple.finder", axis: .vertical, upSign: 1, memory: m)
        XCTAssertEqual(WheelPolarity.upSign(app: "com.apple.finder", axis: .vertical, memory: m), 1)
        XCTAssertTrue(WheelPolarity.isKnown(app: "com.apple.finder", axis: .vertical, memory: m))
    }

    func testAnotherAppsSignIsAHintButDoesNotWaiveCalibration() {
        let m = freshMemory()
        WheelPolarity.learn(app: "com.apple.finder", axis: .vertical, upSign: 1, memory: m)
        XCTAssertEqual(WheelPolarity.upSign(app: "com.avid.ProTools", axis: .vertical, memory: m), 1)
        XCTAssertFalse(WheelPolarity.isKnown(app: "com.avid.ProTools", axis: .vertical, memory: m),
                       "a different app may invert the wheel; it must be asked independently")
    }

    func testConfirmingAnInheritedSignPinsTheProofToThisApp() {
        let m = freshMemory()
        WheelPolarity.learn(app: "first", upSign: 1, memory: m)
        WheelPolarity.learn(app: "second", upSign: 1, memory: m)
        XCTAssertTrue(WheelPolarity.isKnown(app: "second", memory: m))
        WheelPolarity.learn(app: "third", upSign: -1, memory: m)
        XCTAssertEqual(WheelPolarity.upSign(app: "second", memory: m), 1,
                       "independent confirmation cannot remain merely a mutable global hint")
    }

    func testAnAppThatInvertsInternallyKeepsItsOwnSign() {
        // …but an app that inverts the wheel itself must not be dragged back to the machine's sign.
        let m = freshMemory()
        WheelPolarity.learn(app: "com.apple.finder", axis: .vertical, upSign: 1, memory: m)
        WheelPolarity.learn(app: "com.weird.app", axis: .vertical, upSign: -1, memory: m)
        XCTAssertEqual(WheelPolarity.upSign(app: "com.weird.app", axis: .vertical, memory: m), -1)
        XCTAssertEqual(WheelPolarity.upSign(app: "com.apple.finder", axis: .vertical, memory: m), 1)
    }

    func testTheAxesAreLearnedSeparately() {
        // A vertical measurement says nothing about the sideways wheel: that axis keeps its own default
        // until something measures it.
        let m = freshMemory()
        WheelPolarity.learn(app: "com.apple.finder", axis: .vertical, upSign: 1, memory: m)
        XCTAssertEqual(WheelPolarity.upSign(app: "com.apple.finder", axis: .horizontal, memory: m),
                       WheelPolarity.assumedUpSign)
        XCTAssertFalse(WheelPolarity.isKnown(app: "com.apple.finder", axis: .horizontal, memory: m))
    }

    func testAnUnreadablePaneIsAskedOnlyOnce() {
        // Nothing there could name a direction. The default keeps being used — but the question counts as
        // ASKED, or every scroll in that app pays the calibration nudge and a scene build forever.
        let m = freshMemory()
        WheelPolarity.learnUnreadable(app: "com.apple.finder", axis: .vertical, memory: m)
        XCTAssertTrue(WheelPolarity.isKnown(app: "com.apple.finder", axis: .vertical, memory: m))
        XCTAssertEqual(WheelPolarity.upSign(app: "com.apple.finder", axis: .vertical, memory: m),
                       WheelPolarity.assumedUpSign)
    }

    func testAnUnreadablePaneDoesNotShadowTheMachineAnswer() {
        // The marker is an APP row and means "I could not tell", not "there is no answer": the machine's
        // measured sign must still reach that app, whichever order they were recorded in.
        let m = freshMemory()
        WheelPolarity.learnUnreadable(app: "com.apple.finder", axis: .vertical, memory: m)
        WheelPolarity.learn(app: "com.avid.ProTools", axis: .vertical, upSign: 1, memory: m)
        XCTAssertEqual(WheelPolarity.upSign(app: "com.apple.finder", axis: .vertical, memory: m), 1)
    }

    func testARealMeasurementIsNotOverwrittenByAnUnreadableOne() {
        let m = freshMemory()
        WheelPolarity.learn(app: "com.apple.finder", axis: .vertical, upSign: 1, memory: m)
        WheelPolarity.learnUnreadable(app: "com.apple.finder", axis: .vertical, memory: m)
        XCTAssertEqual(WheelPolarity.upSign(app: "com.apple.finder", axis: .vertical, memory: m), 1)
    }

    func testALaterMeasurementCorrectsTheMemory() {
        // The user flips their trackpad setting: the next measured burst must win, not the old row.
        let m = freshMemory()
        WheelPolarity.learn(app: "com.apple.finder", axis: .vertical, upSign: 1, memory: m)
        WheelPolarity.learn(app: "com.apple.finder", axis: .vertical, upSign: -1, memory: m)
        XCTAssertEqual(WheelPolarity.upSign(app: "com.apple.finder", axis: .vertical, memory: m), -1)
    }
}
