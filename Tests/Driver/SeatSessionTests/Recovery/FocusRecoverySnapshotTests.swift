import CoreGraphics
import Foundation
import SeatCore
@testable import SeatSession
import Testing

@Suite("Focus recovery window evidence")
struct FocusRecoverySnapshotTests {
    private static let target = FakeGeometry.adoptedWindow
    private static let user = FakeGeometry.reference(
        frame       : CGRect(x: 100, y: 100, width: 600, height: 500),
        processID   : FakeGeometry.userPID,
        windowNumber: 801
    )
    private static let environment = FocusRecoverySnapshot(
        topologyIsValid: true,
        virtualBounds  : FakeGeometry.virtual,
        physicalBounds : [FakeGeometry.physical],
        windows        : []
    )

    private static func entry(_ window: WindowReference) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: window.processID),
            kCGWindowNumber as String  : NSNumber(value: window.windowNumber),
            kCGWindowBounds as String  : window.frame.dictionaryRepresentation
        ]
    }

    @Test("an unrelated unresolvable window cannot veto recovery, in any list position",
          arguments: 0..<3)
    func unrelatedWindow(_ position: Int) {
        let system = FakeGeometry.reference(
            frame       : FakeGeometry.physical,
            processID   : 169,
            windowNumber: 2
        )
        var entries = [Self.entry(Self.target), Self.entry(Self.user)]
        entries.insert(Self.entry(system), at: position)
        var resolutions: [Int] = []
        let snapshot = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: [Self.target.processID, Self.user.processID],
            entries: entries,
            resolve: { _, number, _ in
                resolutions.append(number)
                return [Self.target, Self.user].first { $0.windowNumber == number }
            }
        )
        #expect(snapshot.topologyIsValid)
        #expect(snapshot.windowsAreComplete)
        #expect(snapshot.containsAdoptedWindows([Self.target]))
        #expect(snapshot.containsOnlyVirtualWindows(of: Self.target.processID))
        #expect(snapshot.containsUserWindow(Self.user, excluding: [Self.target]))
        #expect(!resolutions.contains(system.windowNumber))
    }

    @Test("a missing identity for any relevant process invalidates all window evidence",
          arguments: [FakeGeometry.targetPID, FakeGeometry.userPID])
    func relevantWindowIsUnresolved(_ processID: Int32) {
        let snapshot = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: [Self.target.processID, Self.user.processID],
            entries: [Self.entry(Self.target), Self.entry(Self.user)],
            resolve: { pid, number, _ in
                guard pid != processID else { return nil }
                return [Self.target, Self.user].first { $0.windowNumber == number }
            }
        )
        #expect(snapshot.topologyIsValid)
        #expect(!snapshot.windowsAreComplete)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.firstUnresolvedWindow == (processID == Self.target.processID
            ? Self.target.windowNumber : Self.user.windowNumber))
    }

    @Test("unavailable listings and rows that cannot be classified remain fail closed",
          arguments: 0..<6)
    func unknownEvidence(_ variant: Int) {
        var row = Self.entry(Self.target)
        switch variant {
        case 1: row[kCGWindowOwnerPID as String] = nil
        case 2: row[kCGWindowOwnerPID as String] = NSNumber(value: 0)
        case 3: row[kCGWindowOwnerPID as String] = NSNumber(value: Int64(Int32.max) + 1)
        case 4: row[kCGWindowNumber as String] = nil
        case 5: row[kCGWindowBounds as String] = nil
        default: break
        }
        let snapshot = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: [Self.target.processID],
            entries: variant == 0 ? nil : [row],
            resolve: { _, _, _ in Self.target }
        )
        #expect(snapshot.topologyIsValid)
        #expect(!snapshot.windowsAreComplete)
        #expect(!snapshot.containsAdoptedWindows([Self.target]))
    }

    @Test("scope and completeness apply even when a matching reference was supplied",
          arguments: 0..<3)
    func suppliedEvidenceCannotEscapeScope(_ variant: Int) {
        let snapshot = FocusRecoverySnapshot(
            topologyIsValid   : true,
            virtualBounds     : FakeGeometry.virtual,
            physicalBounds    : [FakeGeometry.physical],
            windows           : [Self.target, Self.user],
            windowsAreComplete: variant != 0,
            coveredProcessIDs : variant == 1 ? [Self.user.processID] : [Self.target.processID]
        )
        #expect(snapshot.containsAdoptedWindows([Self.target]) == (variant == 2))
        #expect(snapshot.containsOnlyVirtualWindows(of: Self.target.processID) == (variant == 2))
        #expect(snapshot.containsUserWindow(Self.user, excluding: [Self.target]) == (variant == 1))
    }

    @Test("all visible windows of an adopted process matter, including unadopted dialogs")
    func physicalDialog() {
        let dialog = FakeGeometry.reference(
            frame       : Self.user.frame,
            windowNumber: 778
        )
        let windows = [Self.target, Self.user, dialog]
        let snapshot = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: [Self.target.processID, Self.user.processID],
            entries: windows.map(Self.entry),
            resolve: { _, number, _ in windows.first { $0.windowNumber == number } }
        )
        #expect(snapshot.windowsAreComplete)
        #expect(snapshot.containsAdoptedWindows([Self.target]))
        #expect(!snapshot.containsOnlyVirtualWindows(of: Self.target.processID))
    }

    @Test("an attestation for a different owner or window cannot authorize the listed row",
          arguments: [false, true])
    func mismatchedIdentity(_ wrongOwner: Bool) {
        let replacement = FakeGeometry.reference(
            frame       : Self.target.frame,
            processID   : wrongOwner ? Self.user.processID : Self.target.processID,
            windowNumber: wrongOwner ? Self.target.windowNumber : 778
        )
        let snapshot = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: [Self.target.processID],
            entries: [Self.entry(Self.target)],
            resolve: { _, _, _ in replacement }
        )
        #expect(!snapshot.windowsAreComplete)
        #expect(snapshot.windows.isEmpty)
    }
}
