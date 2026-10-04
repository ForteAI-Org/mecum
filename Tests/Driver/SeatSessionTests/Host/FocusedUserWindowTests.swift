import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// FocusedUserWindowTests cover local key-window selection without self AX
/// messaging, and retain the ownership checks for an external AX reading.
@MainActor
@Suite("The foreground window of the consumer")
struct FocusedUserWindowTests {

    private static let own = FakeGeometry.reference(
        frame: CGRect(x: 100, y: 100, width: 600, height: 500),
        processID: FakeGeometry.userPID,
        windowNumber: 801
    )

    @Test("Own-process focus uses the local key window without calling Accessibility")
    func localKeyWindow() {
        var calls: [String] = []
        let window = SystemSeatSensing.readFocusedUserWindow(
            processID: Self.own.processID,
            ownProcessID: Self.own.processID,
            readOwnWindowNumber: { calls.append("own"); return Self.own.windowNumber },
            readAccessibilityWindowNumber: { _ in calls.append("ax"); return nil },
            readGeometry: { number in calls.append("geometry"); return number == Self.own.windowNumber ? Self.own : nil }
        )
        #expect(window == Self.own)
        #expect(calls == ["own", "geometry"])
    }

    @Test("An absent local key window refuses without an AX fallback")
    func noLocalWindow() {
        var calls: [String] = []
        let window = SystemSeatSensing.readFocusedUserWindow(
            processID: Self.own.processID,
            ownProcessID: Self.own.processID,
            readOwnWindowNumber: { calls.append("own"); return nil },
            readAccessibilityWindowNumber: { _ in calls.append("ax"); return Self.own.windowNumber },
            readGeometry: { _ in calls.append("geometry"); return Self.own }
        )
        #expect(window == nil)
        #expect(calls == ["own"])
    }

    @Test("External focus retains AX selection and never consults the consumer's key window")
    func externalWindow() {
        let external = FakeGeometry.adoptedWindow
        var calls: [String] = []
        let window = SystemSeatSensing.readFocusedUserWindow(
            processID: external.processID,
            ownProcessID: Self.own.processID,
            readOwnWindowNumber: { calls.append("own"); return Self.own.windowNumber },
            readAccessibilityWindowNumber: { pid in calls.append("ax"); return pid == external.processID ? external.windowNumber : nil },
            readGeometry: { number in calls.append("geometry"); return number == external.windowNumber ? external : nil }
        )
        #expect(window == external)
        #expect(calls == ["ax", "geometry"])
    }

    @Test("Wrong owner or window number cannot attest a focused window", arguments: [false, true])
    func wrongGeometry(wrongOwner: Bool) {
        let wrong = FakeGeometry.reference(
            frame: Self.own.frame,
            processID: wrongOwner ? FakeGeometry.targetPID : Self.own.processID,
            windowNumber: wrongOwner ? Self.own.windowNumber : Self.own.windowNumber + 1
        )
        #expect(SystemSeatSensing.readFocusedUserWindow(
            processID: Self.own.processID,
            ownProcessID: Self.own.processID,
            readOwnWindowNumber: { Self.own.windowNumber },
            readAccessibilityWindowNumber: { _ in Self.own.windowNumber },
            readGeometry: { _ in wrong }
        ) == nil)
    }
}
