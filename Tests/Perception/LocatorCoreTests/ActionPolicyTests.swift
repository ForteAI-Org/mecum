import XCTest
@testable import LocatorCore

final class ActionPolicyTests: XCTestCase {
    func testDestructiveLabelsRefused() {
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Delete"))
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Move to Trash"))
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Sign Out"))
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Send"))
        XCTAssertFalse(ActionPolicy.isDestructive(label: "Export"))
        XCTAssertFalse(ActionPolicy.isDestructive(label: "Play"))
        XCTAssertFalse(ActionPolicy.isDestructive(label: nil))
    }

    func testSafeVerbs() {
        XCTAssertTrue(ActionPolicy.safeVerbs.contains("click"))
        XCTAssertTrue(ActionPolicy.safeVerbs.contains("set_toggle"))
        XCTAssertFalse(ActionPolicy.safeVerbs.contains("type"))
        XCTAssertFalse(ActionPolicy.safeVerbs.contains("drag"))
    }

    func testSceneTokenStableAndStateSensitive() {
        let base = [SceneElement(id: "a", kind: "control", label: "mute", pos: [0, 0, 0.1, 0.1], state: "off")]
        let t1 = SceneSnapshot.makeToken(bundleID: "com.x", windowTitle: "W", elements: base)
        let t1again = SceneSnapshot.makeToken(bundleID: "com.x", windowTitle: "W", elements: base)
        XCTAssertEqual(t1, t1again)   // deterministic / process-stable

        let flipped = [SceneElement(id: "a", kind: "control", label: "mute", pos: [0, 0, 0.1, 0.1], state: "on")]
        XCTAssertNotEqual(t1, SceneSnapshot.makeToken(bundleID: "com.x", windowTitle: "W", elements: flipped))   // state change → token change
    }
}
