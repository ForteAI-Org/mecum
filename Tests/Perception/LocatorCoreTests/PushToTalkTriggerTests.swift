import XCTest
@testable import LocatorCore

/// The push-to-talk guards. These decide whether the microphone opens, so they get tested properly:
/// a false positive means the mic opens while the user types.
final class PushToTalkTriggerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testCleanHoldStartsThenSends() {
        var t = PushToTalkTrigger()
        XCTAssertEqual(t.rightShift(down: true, at: t0), .none)
        XCTAssertEqual(t.armIfHeld(at: t0.addingTimeInterval(0.3)), .startListening)
        XCTAssertTrue(t.isListening)
        XCTAssertEqual(t.rightShift(down: false, at: t0.addingTimeInterval(2)), .sendTranscript)
        XCTAssertFalse(t.isListening)
    }

    func testShortTapNeverOpensTheMic() {
        var t = PushToTalkTrigger()
        _ = t.rightShift(down: true, at: t0)
        XCTAssertEqual(t.rightShift(down: false, at: t0.addingTimeInterval(0.08)), .none)
        // The scheduled arm fires afterwards and must find nothing held.
        XCTAssertEqual(t.armIfHeld(at: t0.addingTimeInterval(0.3)), .none)
        XCTAssertFalse(t.isListening)
    }

    func testShiftLetterTypingIsNotPushToTalk() {
        var t = PushToTalkTrigger()
        _ = t.rightShift(down: true, at: t0)
        XCTAssertEqual(t.otherKeyDown(), .none)                       // capital letter typed
        XCTAssertEqual(t.armIfHeld(at: t0.addingTimeInterval(0.3)), .none)   // chord ⇒ never arms
        XCTAssertEqual(t.rightShift(down: false, at: t0.addingTimeInterval(0.5)), .none)
        XCTAssertFalse(t.isListening)
    }

    func testChordDuringListeningDiscards() {
        var t = PushToTalkTrigger()
        _ = t.rightShift(down: true, at: t0)
        XCTAssertEqual(t.armIfHeld(at: t0.addingTimeInterval(0.3)), .startListening)
        XCTAssertEqual(t.otherKeyDown(), .discardTranscript)          // typing began mid-hold
        XCTAssertFalse(t.isListening)
        XCTAssertEqual(t.rightShift(down: false, at: t0.addingTimeInterval(1)), .none)
    }

    func testArmIsIdempotentWithinOneHold() {
        var t = PushToTalkTrigger()
        _ = t.rightShift(down: true, at: t0)
        XCTAssertEqual(t.armIfHeld(at: t0.addingTimeInterval(0.3)), .startListening)
        XCTAssertEqual(t.armIfHeld(at: t0.addingTimeInterval(0.4)), .none)   // no double-start
    }

    func testConsecutiveHoldsBothWork() {
        var t = PushToTalkTrigger()
        _ = t.rightShift(down: true, at: t0)
        XCTAssertEqual(t.armIfHeld(at: t0.addingTimeInterval(0.3)), .startListening)
        XCTAssertEqual(t.rightShift(down: false, at: t0.addingTimeInterval(1)), .sendTranscript)
        let t1 = t0.addingTimeInterval(5)
        _ = t.rightShift(down: true, at: t1)
        XCTAssertEqual(t.armIfHeld(at: t1.addingTimeInterval(0.3)), .startListening)
        XCTAssertEqual(t.rightShift(down: false, at: t1.addingTimeInterval(1)), .sendTranscript)
    }

    func testChordAfterReleaseDoesNotAffectTheNextHold() {
        var t = PushToTalkTrigger()
        _ = t.rightShift(down: true, at: t0)
        XCTAssertEqual(t.otherKeyDown(), .none)
        XCTAssertEqual(t.rightShift(down: false, at: t0.addingTimeInterval(0.4)), .none)
        XCTAssertEqual(t.otherKeyDown(), .none)   // stray typing between holds
        let t1 = t0.addingTimeInterval(3)
        _ = t.rightShift(down: true, at: t1)
        XCTAssertEqual(t.armIfHeld(at: t1.addingTimeInterval(0.3)), .startListening)
    }

    func testReleaseWithoutArmingSendsNothing() {
        var t = PushToTalkTrigger()
        XCTAssertEqual(t.rightShift(down: false, at: t0), .none)   // release with no press (stale flags)
    }
}
