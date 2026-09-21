import CoreGraphics
import Foundation
import SeatCore
@testable import SeatSession
import Testing
import WindowPlacement

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

    /// The same row with a layer. It is an overload and not a defaulted argument
    /// so that the rows above keep passing `entry` itself to `map`, and so that a
    /// row with no layer key stays the ordinary case: absent is not depth.
    private static func entry(_ window: WindowReference, level: Int) -> [String: Any] {
        var row = entry(window)
        row[kCGWindowLayer as String] = NSNumber(value: level)
        return row
    }

    @Test("an attested off-screen host can coexist with its visible standalone panel",
          arguments: 0..<5)
    func hiddenHostRetainsContainmentEvidence(_ variant: Int) {
        let panel = FakeGeometry.reference(
            frame: Self.target.frame, processID: Self.target.processID, windowNumber: 47_900
        )
        var hidden = Self.entry(Self.target)
        hidden[kCGWindowIsOnscreen as String] = NSNumber(value: variant == 1)
        if variant == 2 { hidden[kCGWindowIsOnscreen as String] = nil }
        let snapshot = FocusRecoverySnapshot.readingWindows(
            in: Self.environment,
            ownedBy: [Self.target.processID, Self.user.processID],
            entries: [Self.entry(panel), Self.entry(Self.user)],
            nonVisibleEntries: variant == 3 ? [hidden, hidden] : [hidden],
            resolve: { _, number, _ in
                if number == Self.target.windowNumber, variant == 4 { return nil }
                return [Self.target, panel, Self.user].first { $0.windowNumber == number }
            }
        )
        #expect(snapshot.containsAdoptedWindows([Self.target, panel]) == (variant == 0 || variant == 2))
        #expect(snapshot.containsOnlyVirtualWindows(of: Self.target.processID))
        #expect(snapshot.containsUserWindow(Self.user, excluding: [Self.target, panel]))
        #expect(snapshot.windows.allSatisfy { $0.windowNumber != Self.target.windowNumber })
    }

    /// The live failure this answers: with the Finder adopted, pid 487 owned the
    /// desktop of each display, so containment could never be true on any
    /// machine. The two variants are the change and its mirror: at the desktop
    /// level the very same window is not containment's business, and at level 0
    /// it still refuses, so the exclusion cannot be mistaken for the check
    /// having been removed.
    @Test("the desktop is behind everything, so containment is not about it",
          arguments: [true, false])
    func desktopLevelIsNotContainment(_ isDesktop: Bool) {
        let desktop = FakeGeometry.reference(
            frame       : FakeGeometry.physical,
            processID   : Self.target.processID,
            windowNumber: 39
        )
        let snapshot = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: [Self.target.processID, Self.user.processID],
            entries: [
                Self.entry(desktop, level: isDesktop ? WindowServerProbe.desktopIconLevel : 0),
                Self.entry(Self.target),
                Self.entry(Self.user)
            ],
            resolve: { _, number, _ in
                [desktop, Self.target, Self.user].first { $0.windowNumber == number }
            }
        )
        #expect(snapshot.windowsAreComplete, "an excluded row is not a row that failed to read")
        #expect(snapshot.containsAdoptedWindows([Self.target]),
                "the adopted window is still required to be inside the virtual display")
        #expect(snapshot.containsOnlyVirtualWindows(of: Self.target.processID) == isDesktop)
        #expect(snapshot.firstWindowOutsideVirtualDisplay(of: Self.target.processID)?.windowNumber
            == (isDesktop ? nil : desktop.windowNumber))

        // A desktop window is not a destination either. `excluding` is empty so
        // that the level is the only thing that can be refusing it here.
        #expect(snapshot.containsUserWindow(desktop, excluding: []) == !isDesktop)
        #expect(snapshot.containsUserWindow(Self.user, excluding: [Self.target]),
                "and the person's own window is untouched by any of it")
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

    /// The live walk carries one memo of owner connections across its rows, and
    /// it carries it inside the `resolve` closure, so this pure form never sees
    /// it. What has to hold is that the closure's memory changes nothing the
    /// walk answers: same entries, same snapshot, complete or not.
    @Test("a memoizing attestation answers what the unmemoized one answers",
          arguments: [false, true])
    func memoizedWalkMatchesUnmemoized(_ userIsUnresolvable: Bool) {
        let second = FakeGeometry.reference(
            frame       : Self.target.frame,
            processID   : Self.target.processID,
            windowNumber: 778
        )
        let known = [Self.target, second, Self.user]
        let entries = known.map(Self.entry)
        let scope: Set<Int32> = [Self.target.processID, Self.user.processID]
        // The leg the memo removes: one process resolution per owner. Refusing
        // one process is the incomplete case, which a memo may not turn into an
        // answer.
        func process(of processID: Int32) -> Int32? {
            userIsUnresolvable && processID == Self.user.processID ? nil : processID
        }

        var plainResolutions = 0
        let plain = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: scope,
            entries: entries,
            resolve: { processID, number, _ in
                plainResolutions += 1
                guard process(of: processID) != nil else { return nil }
                return known.first { $0.windowNumber == number }
            }
        )

        var memoResolutions = 0
        var processes: [Int32: Int32] = [:]
        let memoized = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: scope,
            entries: entries,
            resolve: { processID, number, _ in
                if processes[processID] == nil {
                    memoResolutions += 1
                    guard let resolved = process(of: processID) else { return nil }
                    processes[processID] = resolved
                }
                return known.first { $0.windowNumber == number }
            }
        )

        #expect(memoized.windows == plain.windows)
        #expect(memoized.windowsAreComplete == plain.windowsAreComplete)
        #expect(memoized.firstUnresolvedWindow == plain.firstUnresolvedWindow)
        #expect(memoized.coveredProcessIDs == plain.coveredProcessIDs)
        #expect(memoized.windowsAreComplete == !userIsUnresolvable)
        // Three rows, two owners: the second window of the first owner is the
        // resolution the memo spares, and the refused owner is still refused.
        #expect(plainResolutions == 3)
        #expect(memoResolutions == 2)
    }

    /// Why the live walk's memo is a local of the walk and dies with it. A
    /// connection ID can be handed to a new process after the old one exits, so
    /// a memo held across walks answers a row with the previous owner's process.
    @Test("a memo carried into the next walk poisons it, a fresh one does not",
          arguments: [true, false])
    func memoDiesWithItsWalk(_ carriedOver: Bool) {
        let known = [Self.target, Self.user]
        // One owner connection per process here, so a stale entry is the whole
        // hazard: the user's connection still naming the target's process.
        var processes: [Int32: Int32] = carriedOver
            ? [Self.user.processID: Self.target.processID]
            : [:]
        let snapshot = FocusRecoverySnapshot.readingWindows(
            in     : Self.environment,
            ownedBy: [Self.target.processID, Self.user.processID],
            entries: known.map(Self.entry),
            resolve: { processID, number, _ in
                let owner = processes[processID] ?? processID
                processes[processID] = owner
                guard let window = known.first(where: { $0.windowNumber == number }) else {
                    return nil
                }
                return FakeGeometry.reference(
                    frame       : window.frame,
                    processID   : owner,
                    windowNumber: number
                )
            }
        )

        #expect(snapshot.windowsAreComplete == !carriedOver)
        #expect(snapshot.firstUnresolvedWindow == (carriedOver ? Self.user.windowNumber : nil))
        #expect(snapshot.windows == (carriedOver ? [] : known))
    }
}
