//
//  CrossCheckedSurfaceReaderTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import ApplicationServices
import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing
import WindowPlacement

@Suite("The cross-checked assigned-surface reader")
struct CrossCheckedSurfaceReaderTests {

    @Test("a transient AX timeout gets one bounded recovery attempt")
    func transientAccessibilityFailureGetsOneRecovery() throws {
        var timeouts: [Float] = []
        let result: Result<Int, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(
                deadlineNanoseconds: 2_000_000_000,
                now: { 1_000_000_000 }
            ) { timeout in
                timeouts.append(timeout)
                return timeouts.count == 1 ? (.cannotComplete, nil) : (.success, 41)
            }

        #expect(try result.get() == 41)
        #expect(timeouts == [0.1, 0.5])
    }

    @Test("a permanent AX failure is not retried")
    func permanentAccessibilityFailureIsNotRetried() {
        var attempts = 0
        let result: Result<Int, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(
                deadlineNanoseconds: 2_000_000_000,
                now: { 1_000_000_000 }
            ) { _ in
                attempts += 1
                return (.attributeUnsupported, nil)
            }

        guard case .failure(let failure) = result else {
            Issue.record("an unsupported attribute was accepted")
            return
        }
        #expect(attempts == 1)
        #expect(failure.error == .attributeUnsupported)
        #expect(failure.attempts == 1)
    }

    @Test("the absolute pass deadline prevents a recovery attempt")
    func passDeadlineBoundsRecovery() {
        var clock: IndexingIterator<[UInt64]> = [1_000_000_000, 2_000_000_000].makeIterator()
        var attempts = 0
        let result: Result<Int, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(
                deadlineNanoseconds: 1_500_000_000,
                now: { clock.next() ?? UInt64(2_000_000_000) }
            ) { _ in
                attempts += 1
                return (.cannotComplete, nil)
            }

        guard case .failure(let failure) = result else {
            Issue.record("a read beyond the pass deadline was accepted")
            return
        }
        #expect(attempts == 1)
        #expect(failure.attempts == 1)
    }

    @Test("a batched slot carrying an AXError is told apart from one carrying a value")
    func batchedSlotErrorIsDecoded() throws {
        var code = AXError.cannotComplete.rawValue
        let failed = try #require(AXValueCreate(.axError, &code))
        var point = CGPoint(x: 3, y: 4)
        let geometry = try #require(AXValueCreate(.cgPoint, &point))

        #expect(CrossCheckedSurfaceReader.slotError(failed) == .cannotComplete)
        // Everything else is a value, so the required and the optional callers
        // decide on it as they did on a single read's value.
        #expect(CrossCheckedSurfaceReader.slotError(geometry) == nil)
        #expect(CrossCheckedSurfaceReader.slotError("AXWindow" as CFString) == nil)
        #expect(CrossCheckedSurfaceReader.slotError(kCFBooleanTrue) == nil)
        #expect(CrossCheckedSurfaceReader.slotError(kCFNull) == nil)
    }

    @Test("an AXUnknown top-level movable raiseable window is an interactive panel")
    func operableUnknownWindowIsSelectable() {
        let role = CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: "AXUnknown",
            positionIsSettable: true,
            actions: [kAXRaiseAction as String],
            childCount: 6
        )

        #expect(role == .interactivePanel)
    }

    @Test("an AXUnknown window without both operability traits has no role")
    func unknownDecorationIsNotPromoted() {
        #expect(CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: "AXUnknown",
            positionIsSettable: false,
            actions: [kAXRaiseAction as String],
            childCount: 6
        ) == nil)
        #expect(CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: "AXUnknown",
            positionIsSettable: true,
            actions: [],
            childCount: 6
        ) == nil)
    }

    @Test("a window with nothing in it is no candidate, whatever its subrole says")
    func emptyWindowIsNotACandidate() {
        // Measured on Finder: raising the seated Downloads window publishes a
        // second AXWindow, subrole AXDialog, 66 by 20 points, no children, and
        // destroyed under a second. The Downloads window itself reads six.
        #expect(CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: kAXDialogSubrole as String,
            positionIsSettable: true,
            actions: [kAXRaiseAction as String],
            childCount: 0
        ) == nil)
        #expect(CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: kAXDialogSubrole as String,
            positionIsSettable: true,
            actions: [kAXRaiseAction as String],
            childCount: 6
        ) == .dialog)
        // A count nobody could take is not a count of zero, and it is answered
        // the same way for the same reason: nothing is targeted on a trait this
        // pass did not read. The window stays `roleNotRead` until one does.
        #expect(CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: kAXDialogSubrole as String,
            positionIsSettable: true,
            actions: [kAXRaiseAction as String],
            childCount: nil
        ) == nil)
    }

    @Test("emptiness answers for every role the reader can answer, and not for AXDialog alone")
    func emptinessGatesEveryRole() {
        let answerable: [(role: String, subrole: String?)] = [
            (kAXSheetRole  as String, nil),
            (kAXDrawerRole as String, nil),
            (kAXWindowRole as String, kAXStandardWindowSubrole as String),
            (kAXWindowRole as String, kAXDialogSubrole as String),
            (kAXWindowRole as String, kAXSystemDialogSubrole as String),
            (kAXWindowRole as String, kAXFloatingWindowSubrole as String),
            (kAXWindowRole as String, kAXSystemFloatingWindowSubrole as String),
            (kAXWindowRole as String, "AXUnknown")
        ]
        for entry in answerable {
            let named = "\(entry.role)/\(entry.subrole ?? "no subrole")"
            #expect(CrossCheckedSurfaceReader.role(
                named: entry.role,
                subrole: entry.subrole,
                positionIsSettable: true,
                actions: [kAXRaiseAction as String],
                childCount: 0
            ) == nil, "\(named) with nothing in it is nobody's target")
            #expect(CrossCheckedSurfaceReader.role(
                named: entry.role,
                subrole: entry.subrole,
                positionIsSettable: true,
                actions: [kAXRaiseAction as String],
                childCount: 1
            ) != nil, "\(named) with one child is the role it says it is")
        }
    }

    // MARK: An accessibility entry that is not a window

    @Test("an entry that positively answers no window leaves the application's scope")
    func entryWithoutAWindowIsExcluded() {
        #expect(CrossCheckedSurfaceReader.scopeOutcome(
            of: .success(.noWindow),
            processID: 487,
            index: 2
        ) == .failure(.notAWindow(.identityIsZero)))
    }

    @Test("an entry whose readable role is no window role leaves the application's scope")
    func readableNonWindowRoleIsExcluded() {
        // Measured on 26A428: Finder's desktop entry reads AXScrollArea for
        // AXRole, while its identity read answers illegalArgument, -25201.
        #expect(CrossCheckedSurfaceReader.roleScopeOutcome(
            of: "AXScrollArea" as CFString,
            processID: 487
        ) == .failure(.notAWindow(.role("AXScrollArea"))))

        // A status item does not reach an AXWindows list on this build, but if
        // one did its role would be the reading that removes it.
        #expect(CrossCheckedSurfaceReader.roleScopeOutcome(
            of: kAXMenuBarItemRole as CFString,
            processID: 484
        ) == .failure(.notAWindow(.role(kAXMenuBarItemRole as String))))
    }

    @Test("the three window roles stay in the application's scope")
    func windowRolesStayInScope() {
        let windowRoles = [
            kAXWindowRole as String,
            kAXSheetRole  as String,
            kAXDrawerRole as String
        ]
        for roleName in windowRoles {
            #expect(CrossCheckedSurfaceReader.roleScopeOutcome(
                of: roleName as CFString,
                processID: 487
            ) == .success(roleName))
        }
    }

    @Test("an entry whose role cannot be read fails the pass instead of leaving the scope")
    func unreadableRoleStillFailsThePass() throws {
        // The destroyed element the whole discriminator rests on: AXRole fails
        // for it, and failing the pass is the outcome that has to stay.
        var code = AXError.cannotComplete.rawValue
        let failed = try #require(AXValueCreate(.axError, &code))

        #expect(CrossCheckedSurfaceReader.roleScopeOutcome(
            of: failed,
            processID: 487
        ) == .failure(.unreadable(.attributeUnavailable(
            processID: 487,
            attribute: kAXRoleAttribute,
            error    : AXError.cannotComplete.rawValue
        ))))

        #expect(CrossCheckedSurfaceReader.roleScopeOutcome(
            of: nil,
            processID: 487
        ) == .failure(.unreadable(.attributeUnavailable(
            processID: 487,
            attribute: kAXRoleAttribute,
            error    : AXError.success.rawValue
        ))))
    }

    @Test("an entry whose identity read failed still fails the pass, naming its AXError")
    func failedIdentityReadStillFailsThePass() {
        // A window role keeps the entry in scope, so its identity read is what
        // decides it, and a read that failed still fails the whole pass.
        #expect(CrossCheckedSurfaceReader.roleScopeOutcome(
            of: kAXWindowRole as CFString,
            processID: 487
        ) == .success(kAXWindowRole as String))

        // Measured on 26A428: Finder's desktop entry answers illegalArgument,
        // -25201, which is a read that failed and never an exclusion.
        #expect(CrossCheckedSurfaceReader.scopeOutcome(
            of: .success(.readFailed(.illegalArgument)),
            processID: 487,
            index: 2
        ) == .failure(.unreadable(.windowIdentityReadFailed(
            processID: 487,
            index    : 2,
            error    : AXError.illegalArgument.rawValue
        ))))

        // The same cause arriving the way the bounded read delivers it, after
        // the one recovery attempt a `.cannotComplete` is allowed.
        #expect(CrossCheckedSurfaceReader.scopeOutcome(
            of: .failure(BoundedAccessibilityRead.Failure(error: .cannotComplete, attempts: 2)),
            processID: 487,
            index: 2
        ) == .failure(.unreadable(.windowIdentityReadFailed(
            processID: 487,
            index    : 2,
            error    : AXError.cannotComplete.rawValue
        ))))

        // The evidence has to reach the sentence, which is the half of this
        // that a report reads: the branch and its code, not "did not resolve".
        #expect(
            CrossCheckedSurfaceReadFailure
                .windowIdentityReadFailed(processID: 487, index: 2, error: -25201)
                .description
                == "Accessibility entry 2 for process 487 refused its WindowServer identity "
                    + "read (AXError -25201)"
        )
    }

    @Test("an unresolved _AXUIElementGetWindow is named as the symbol and not as a read")
    func missingPrimitiveIsNamedAsTheSymbol() {
        #expect(CrossCheckedSurfaceReader.scopeOutcome(
            of: .success(.symbolUnavailable),
            processID: 487,
            index: 2
        ) == .failure(.unreadable(
            .windowIdentityPrimitiveUnavailable(processID: 487, index: 2)
        )))
    }

    @Test("the pass deadline keeps its own cause instead of becoming an AXError")
    func passDeadlineKeepsItsOwnCause() {
        #expect(CrossCheckedSurfaceReader.scopeOutcome(
            of: .failure(BoundedAccessibilityRead.Failure(error: .cannotComplete, attempts: 0)),
            processID: 487,
            index: 2
        ) == .failure(.unreadable(.passDeadlineExpired)))
    }

    @Test("an entry that answers a window keeps its number and stays in scope")
    func resolvedEntryKeepsItsNumber() {
        #expect(CrossCheckedSurfaceReader.scopeOutcome(
            of: .success(.number(39)),
            processID: 487,
            index: 0
        ) == .success(39))
    }

    @Test("an excluded entry is no member, while an unattested one still refuses completeness")
    func exclusionDoesNotWeakenCompleteness() {
        // The scope the join is handed once the entry has left it: the ordinary
        // windows qualify and nothing carries the excluded entry.
        let excluded = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false),
                record(42, role: .dialog,   minimised: false, modal: false),
            ]
        )

        #expect(excluded.inventory.completeness.isQualified)
        #expect(excluded.inventory.rows.map(\.surface.reference.windowNumber) == [41, 42])
        #expect(excluded.claims.roles.map(\.surface.windowNumber) == [41, 42])
        #expect(excluded.claims.visibilities.map(\.surface.windowNumber) == [41, 42])

        // The same application with a third AX window kept in scope and no
        // attested counterpart: the completeness rule is exactly as it was.
        let unattested = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false),
                record(42, role: .dialog,   minimised: false, modal: false),
                record(43, role: .document, minimised: false, modal: false),
            ]
        )

        #expect(!unattested.inventory.completeness.isQualified)
        #expect(unattested.inventory.rows.map(\.surface.reference.windowNumber) == [41, 42])
    }

    @Test("matching AX and WindowServer sets qualify membership, role and visibility")
    func exactSetQualifies() throws {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true)],
            accessibility: [record(41, role: .document, minimised: false, modal: false)]
        )

        #expect(snapshot.inventory.completeness.isQualified)
        #expect(snapshot.inventory.rows.map(\.surface.reference.windowNumber) == [41])
        let role = try #require(snapshot.claims.roles.first)
        #expect(role.surface.windowNumber == 41)
        #expect(role.role == .document)
        let visibility = try #require(snapshot.claims.visibilities.first)
        #expect(visibility.surface.windowNumber == 41)
        #expect(visibility.state == .visibleInteractive)
    }

    @Test("WindowServer-only auxiliary surfaces do not widen the AX window scope")
    func serverOnlyAuxiliarySurfacesAreOutsideTheInventory() {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [
                surface(41, visible: true),
                surface(42, visible: false),
                surface(43, visible: false),
                surface(44, visible: false),
                surface(45, visible: false),
                surface(46, visible: false),
                surface(47, visible: false),
                surface(48, visible: false),
                surface(49, visible: false),
            ],
            accessibility: [record(41, role: .document, minimised: false, modal: false)]
        )

        #expect(snapshot.inventory.completeness.isQualified)
        #expect(snapshot.inventory.rows.map(\.surface.reference.windowNumber) == [41])
    }

    @Test("an AX window without a matching attested WindowServer row keeps inventory incomplete")
    func accessibilityOnlyWindowRefusesCompleteness() {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false),
                record(42, role: .dialog, minimised: false, modal: true),
            ]
        )

        #expect(!snapshot.inventory.completeness.isQualified)
        #expect(snapshot.inventory.completeness.unqualifiedReason?.contains("axOnly=[77:42]") == true)
    }

    @Test("minimised, hidden, modal and unreadable modal facts stay distinct")
    func nativeFactsRemainDistinct() {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [
                surface(41, visible: false),
                surface(42, visible: false),
                surface(43, visible: true),
            ],
            accessibility: [
                record(41, role: .document, minimised: true,  modal: false),
                record(42, role: .dialog,   minimised: false, modal: true, hidden: true),
                record(43, role: .document, minimised: false, modal: nil),
            ]
        )

        let states = Dictionary(uniqueKeysWithValues: snapshot.claims.visibilities.map {
            ($0.surface.windowNumber, $0.state)
        })
        #expect(states[41] == .minimisedEstablished)
        #expect(states[42] == .hiddenEstablished)
        #expect(states[43] == .uncertain)
        #expect(snapshot.claims.modals.count == 1)
        #expect(snapshot.claims.modals.first?.modal.windowNumber == 42)
    }

    @Test("the unique focused window supplies multi-window selection order")
    func focusedWindowQualifiesCurrentTarget() throws {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, main: true),
                record(42, role: .document, minimised: false, modal: false, focused: true),
            ],
            observedAtNanoseconds: 900
        )

        let claim = try #require(snapshot.claims.recency.only)
        #expect(claim.surface.windowNumber == 42)
        #expect(claim.signal == .returnedToFront)
        #expect(claim.observedAtNanoseconds == 900)
        #expect(claim.unqualifiedReason == nil)
    }

    @Test("the main window selects a document even while no window is focused")
    func mainWindowQualifiesCurrentTarget() throws {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, main: false),
                record(42, role: .document, minimised: false, modal: false, main: true),
            ],
            observedAtNanoseconds: 901
        )

        #expect(try #require(snapshot.claims.recency.only).surface.windowNumber == 42)
    }

    @Test("a modal child names its parent and blocks only that window")
    func modalChildCarriesParentage() throws {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, main: true),
                record(
                    42,
                    role: .dialog,
                    minimised: false,
                    modal: true,
                    focused: true,
                    parent: 41
                ),
            ],
            observedAtNanoseconds: 902
        )

        let parent = try #require(snapshot.claims.parents.only)
        #expect(parent.child.windowNumber == 42)
        #expect(parent.parent.windowNumber == 41)
        let modal = try #require(snapshot.claims.modals.only)
        #expect(modal.scope == .window(identity(41)))
        #expect(try #require(snapshot.claims.recency.only).surface.windowNumber == 42)
    }

    @Test("contradictory focused windows fail closed instead of inventing an order")
    func contradictoryFocusHasNoOrder() {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, main: true, focused: true),
                record(42, role: .document, minimised: false, modal: false, focused: true),
            ],
            observedAtNanoseconds: 903
        )

        #expect(snapshot.claims.recency.isEmpty)
    }

    @Test("an incomplete cross-check cannot qualify application-local order")
    func incompleteInventoryHasNoOrder() {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, main: true),
                record(42, role: .document, minimised: false, modal: false),
            ],
            observedAtNanoseconds: 904
        )

        #expect(!snapshot.inventory.completeness.isQualified)
        #expect(snapshot.claims.recency.isEmpty)
    }

    @Test("a minimised main window cannot become current through recency")
    func minimisedMainHasNoOrder() {
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: false), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: true, modal: false, main: true),
                record(42, role: .document, minimised: false, modal: false),
            ],
            observedAtNanoseconds: 905
        )

        #expect(snapshot.claims.recency.isEmpty)
    }

    @Test("polling the same current window is not a new recency event")
    func currentWindowTransitionsAreEdgeTriggered() throws {
        let filter = ApplicationTargetTransitionFilter()
        let first = filter.filter(CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, focused: true),
                record(42, role: .document, minimised: false, modal: false),
            ],
            observedAtNanoseconds: 906
        ))
        let unchanged = filter.filter(CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, focused: true),
                record(42, role: .document, minimised: false, modal: false),
            ],
            observedAtNanoseconds: 907
        ))
        let changed = filter.filter(CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false),
                record(42, role: .document, minimised: false, modal: false, focused: true),
            ],
            observedAtNanoseconds: 908
        ))

        #expect(try #require(first.claims.recency.only).signal == .appeared)
        #expect(unchanged.claims.recency.isEmpty)
        #expect(try #require(changed.claims.recency.only).signal == .returnedToFront)
        #expect(changed.claims.recency.only?.surface.windowNumber == 42)
    }

    @Test("a repeated native reading does not cancel an explicit window choice")
    func nativeBatchPreservesExplicitChoice() {
        let raw = CrossCheckedSurfaceReader.assemble(
            windowServer: [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, focused: true),
                record(42, role: .document, minimised: false, modal: false),
            ],
            observedAtNanoseconds: 909
        )
        let filter = ApplicationTargetTransitionFilter()
        let first  = filter.filter(raw)
        let repeatReading = filter.filter(raw)
        let assignment = SeatAssignmentKit()
        _ = assignment.handOver(
            instance   : identity(41).process,
            attestation: .windowServerAttested,
            at         : 0
        )
        let selection = SeatTargetSelectionKit(assignment: assignment)
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)

        selection.ingest(first.inventory, within: bounds, at: 0)
        selection.ingest(first.inventory, within: bounds, at: 10_000_000)
        apply(first.claims, to: selection)

        #expect(selection.selected?.surface.windowNumber == 41)
        _ = selection.selectExplicitly(identity(42))
        #expect(selection.selected?.surface.windowNumber == 42)

        selection.ingest(repeatReading.inventory, within: bounds, at: 20_000_000)
        apply(repeatReading.claims, to: selection)

        #expect(selection.selected?.surface.windowNumber == 42)
        #expect(selection.selected?.reason == .explicitChoice)
        #expect(!selection.status().operability.causes.contains {
            if case .explicitSelectionRequired = $0 { true } else { false }
        })
    }

    @Test("a surface the application stopped scoping is reported at once and confirmed after its grace")
    func withdrawalIsConfirmedOnlyAfterItsGrace() {
        let retained = identity(42)
        let raw = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [record(41, role: .document, minimised: false, modal: false, focused: true)],
            retaining    : [retained],
            observedAtNanoseconds: 0
        )

        // The window server still shows it and the application no longer lists
        // it. One pass cannot tell that from an accessibility read that was
        // slow, so the pass reports it and keeps failing closed.
        #expect(raw.withdrawnByApplication == [retained])
        #expect(!raw.inventory.completeness.isQualified)

        let filter = ApplicationTargetTransitionFilter()
        let grace  = ApplicationTargetTransitionFilter.withdrawalGraceNanoseconds
        #expect(filter.filter(raw, at: 0).withdrawnByApplication.isEmpty)
        #expect(filter.filter(raw, at: grace - 1).withdrawnByApplication.isEmpty)
        #expect(filter.filter(raw, at: grace).withdrawnByApplication == [retained])
    }

    @Test("a surface that comes back inside the application's scope is never confirmed")
    func withdrawalIsForgottenWhenTheWindowReturns() {
        let retained = identity(42)
        let windowServer = [surface(41, visible: true), surface(42, visible: true)]
        let withdrawn = CrossCheckedSurfaceReader.assemble(
            windowServer : windowServer,
            accessibility: [record(41, role: .document, minimised: false, modal: false, focused: true)],
            retaining    : [retained],
            observedAtNanoseconds: 0
        )
        let returned = CrossCheckedSurfaceReader.assemble(
            windowServer : windowServer,
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, focused: true),
                record(42, role: .document, minimised: false, modal: false),
            ],
            retaining    : [retained],
            observedAtNanoseconds: 0
        )
        let filter = ApplicationTargetTransitionFilter()
        let grace  = ApplicationTargetTransitionFilter.withdrawalGraceNanoseconds

        _ = filter.filter(withdrawn, at: 0)
        #expect(filter.filter(returned, at: grace).withdrawnByApplication.isEmpty)
        // And the clock starts again, so the earlier absence cannot be spent
        // later on a window that was listed in between.
        _ = filter.filter(withdrawn, at: grace)
        #expect(filter.filter(withdrawn, at: grace + 1).withdrawnByApplication.isEmpty)
    }

    @Test("a retained surface the window server answers no row for is a confirmed destruction")
    func absentWindowServerRowIsADestruction() {
        let retained = identity(42)
        let raw = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true)],
            accessibility: [record(41, role: .document, minimised: false, modal: false, focused: true)],
            retaining    : [retained],
            observedAtNanoseconds: 0
        )

        // The pass named 42 in its own window server request and got nothing
        // back, which is the one absence that proves the window ended.
        #expect(raw.destroyedByWindowServer == [retained])
        #expect(raw.withdrawnByApplication.isEmpty)
        #expect(raw.inventory.completeness.isQualified, "The destroyed window disqualifies nothing")
        #expect(raw.inventory.rows.count == 1)
    }

    @Test("a destruction is reported at once and stops the surface being looked up")
    func destructionNeedsNoGrace() {
        let retained = identity(42)
        let raw = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true)],
            accessibility: [record(41, role: .document, minimised: false, modal: false, focused: true)],
            retaining    : [retained],
            observedAtNanoseconds: 0
        )
        let filter = ApplicationTargetTransitionFilter()

        #expect(filter.filter(raw, at: 0).destroyedByWindowServer == [retained])
        #expect(!filter.retainedIdentities(ownedBy: [77]).contains(retained))
    }

    @Test("a retained surface the window server still holds is not a destruction")
    func presentRowIsNotADestruction() {
        let retained = identity(42)
        let hidden = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: false)],
            accessibility: [record(41, role: .document, minimised: false, modal: false, focused: true)],
            retaining    : [retained],
            observedAtNanoseconds: 0
        )
        let onScreen = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [record(41, role: .document, minimised: false, modal: false, focused: true)],
            retaining    : [retained],
            observedAtNanoseconds: 0
        )

        #expect(hidden.destroyedByWindowServer.isEmpty)
        #expect(onScreen.destroyedByWindowServer.isEmpty)
        #expect(onScreen.withdrawnByApplication == [retained])
    }

    // MARK: The nested dialog that took the surface under it with it

    /// The measured shape of the defect: 41 is the host, 42 the open panel's
    /// sheet, 43 the Go to folder dialog the sheet opened. The top
    /// accessibility level shows the host and the dialog, the window server
    /// shows all three, and the dialog names the sheet as the window it belongs
    /// to.
    private func nestedDialog(parentOfDialog parent: Int?) -> AssignedSurfaceSnapshot {
        CrossCheckedSurfaceReader.assemble(
            windowServer : [
                surface(41, visible: true),
                surface(42, visible: true),
                surface(43, visible: true),
            ],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false),
                record(
                    43,
                    role     : .dialog,
                    minimised: false,
                    modal    : true,
                    focused  : true,
                    parent   : parent
                ),
            ],
            retaining    : [identity(42)],
            observedAtNanoseconds: 0
        )
    }

    @Test("an ancestor its child attests is kept although the top level shows only the child")
    func attestedAncestorSurvivesItsChild() {
        let raw = nestedDialog(parentOfDialog: 42)

        #expect(raw.retained[identity(42)] == .obscuredByChild(identity(43)))
        #expect(raw.withdrawnByApplication.isEmpty, "a window on screen is not one the seat may close")
        #expect(raw.destroyedByWindowServer.isEmpty)
        #expect(raw.inventory.completeness.isQualified,
                "the surface is accounted for, so the pass carries the whole application")
        #expect(raw.inventory.rows.map(\.surface.reference.windowNumber) == [41, 42, 43])
        // And the relation survives with it: without the parent the dialog's
        // own modality would be published against the whole application, which
        // blocks the host window the person is working in.
        #expect(raw.claims.modals.only?.scope == .window(identity(42)))
        #expect(raw.claims.parents.only?.parent == identity(42))
    }

    @Test("an ancestor nothing attests still takes the withdrawal path")
    func anUnattestedAncestorIsNotKept() {
        let raw = nestedDialog(parentOfDialog: nil)

        #expect(raw.retained[identity(42)] == .withdrawn)
        #expect(!raw.inventory.completeness.isQualified)
        #expect(!raw.inventory.rows.map(\.surface.reference.windowNumber).contains(42))
        #expect(raw.claims.modals.only?.scope == .application)
    }

    @Test("an ancestor kept under its child is never confirmed gone, however long it stays there")
    func attestedAncestorOutlastsEveryGrace() {
        let filter = ApplicationTargetTransitionFilter()
        let grace  = ApplicationTargetTransitionFilter.withdrawalGraceNanoseconds

        _ = filter.filter(nestedDialog(parentOfDialog: 42), at: 0)
        let late = filter.filter(nestedDialog(parentOfDialog: 42), at: grace &* 10)

        #expect(late.withdrawnByApplication.isEmpty, "time alone is no proof that a window ended")
        #expect(late.retained[identity(42)] == .obscuredByChild(identity(43)))
        #expect(filter.retainedIdentities(ownedBy: [77]).contains(identity(42)),
                "it is still looked up, so its real destruction can still be proved")
    }

    @Test("a withdrawal inside its grace reads as temporarily unreadable and nothing else")
    func withdrawalInsideItsGraceIsNamedForWhatItIs() {
        let raw    = nestedDialog(parentOfDialog: nil)
        let filter = ApplicationTargetTransitionFilter()
        let grace  = ApplicationTargetTransitionFilter.withdrawalGraceNanoseconds

        #expect(filter.filter(raw, at: 0).retained[identity(42)] == .temporarilyUnreadable)
        #expect(filter.filter(raw, at: grace).retained[identity(42)] == .withdrawn)
    }

    @Test("a retained Window ID the server answers a different window for is unrelated")
    func aReusedWindowIdIsNeitherGoneNorWithdrawn() {
        let reused = WindowSurface(
            reference: WindowReference(
                identity: WindowIdentity(
                    process: ProcessIdentity(
                        processID       : 77,
                        serialNumberHigh: 3,
                        serialNumberLow : 9
                    ),
                    windowNumber     : 42,
                    ownerConnectionID: 909
                ),
                frame: CGRect(x: 42, y: 20, width: 640, height: 480)
            ),
            level    : 0,
            isVisible: true
        )
        let raw = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), reused],
            accessibility: [record(41, role: .document, minimised: false, modal: false, focused: true)],
            retaining    : [identity(42)],
            observedAtNanoseconds: 0
        )

        #expect(raw.retained[identity(42)] == .unrelated)
        #expect(raw.destroyedByWindowServer.isEmpty, "a window nobody read is not a window that ended")
        #expect(raw.withdrawnByApplication.isEmpty)
    }

    // MARK: The short-lived system surface that suspended a seat

    @Test("a surface an inexact pass attested is looked up again, so its closure can be proved")
    func inexactPassRetainsWhatItAttested() {
        let filter     = ApplicationTargetTransitionFilter()
        let assignment = SeatAssignmentKit()
        // The helper frames a surface at x equal to its window number, so the
        // seat is placed where the window numbers of the live failure land.
        let bounds = CGRect(x: 41_000, y: 0, width: 2_000, height: 1_000)
        _ = assignment.handOver(
            instance   : identity(41_366).process,
            attestation: .windowServerAttested,
            at         : 0
        )

        // 41368 is in the application's own scope with nothing attesting it,
        // which is what makes the pass inexact while 41367 is folded in as a
        // member of the assignment like any other row.
        let opened = filter.filter(CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41_366, visible: true), surface(41_367, visible: true)],
            accessibility: [
                record(41_366, role: .document, minimised: false, modal: false, focused: true),
                record(41_367, role: .dialog, minimised: false, modal: false),
                record(41_368, role: .dialog, minimised: false, modal: false),
            ],
            retaining    : filter.retainedIdentities(ownedBy: [77]),
            observedAtNanoseconds: 0
        ), at: 0)

        #expect(!opened.inventory.completeness.isQualified)
        _ = assignment.ingest(opened.inventory, within: bounds, at: 0)
        #expect(assignment.inventory.members.map(\.windowNumber) == [41_366, 41_367])

        // 41367 was destroyed a second later, which is what these surfaces do.
        let closing = filter.filter(CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41_366, visible: true)],
            accessibility: [
                record(41_366, role: .document, minimised: false, modal: false, focused: true),
            ],
            retaining    : filter.retainedIdentities(ownedBy: [77]),
            observedAtNanoseconds: 10_000_000
        ), at: 10_000_000)

        #expect(
            closing.destroyedByWindowServer == [identity(41_367)],
            "the pass has to name 41367 to be told it is gone"
        )
        for gone in closing.destroyedByWindowServer {
            assignment.confirmClosure(
                of      : gone.windowNumber,
                evidence: .windowServerConfirmedDestruction
            )
        }
        let settled = assignment.ingest(closing.inventory, within: bounds, at: 10_000_000)

        #expect(!settled.blocks.contains(.surfaceAbsent(windowNumber: 41_367)))
        #expect(settled.blocks.isEmpty)
        #expect(settled.containmentIsVerified)
    }

    @Test("a withdrawal inside its grace keeps being looked up, so the grace can run out")
    func withdrawalInsideItsGraceStaysRetained() {
        let retained = identity(42)
        let raw = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [record(41, role: .document, minimised: false, modal: false, focused: true)],
            retaining    : [retained],
            observedAtNanoseconds: 0
        )
        let filter = ApplicationTargetTransitionFilter()
        let grace  = ApplicationTargetTransitionFilter.withdrawalGraceNanoseconds

        // It carries no row of its own, so only the pending withdrawal keeps it
        // in the lookup, and dropping it early would strand it absent forever.
        _ = filter.filter(raw, at: 0)
        #expect(filter.retainedIdentities(ownedBy: [77]).contains(retained))
        #expect(filter.filter(raw, at: grace).withdrawnByApplication == [retained])
        #expect(!filter.retainedIdentities(ownedBy: [77]).contains(retained))
    }

    @Test("an inexact pass is retained whole and still emits no recency")
    func retentionFromAnInexactPassCarriesNoRecency() {
        let filter = ApplicationTargetTransitionFilter()
        let raw = AssignedSurfaceSnapshot(
            inventory: SurfaceInventoryReading(
                rows: [
                    SurfaceInventoryReading.Row(
                        surface   : surface(41, visible: true),
                        provenance: .windowServerAttestedIdentity
                    ),
                ],
                completeness: .incomplete(reason: "written, so the guard is exercised on its own")
            ),
            claims: SelectionClaimBatch(recency: [
                RecencyClaim(
                    surface              : identity(41),
                    signal               : .returnedToFront,
                    provenance           : .qualifiedFrontOrderAttestation,
                    origin               : .application(provenance: .qualifiedRaiseAttribution),
                    observedAtNanoseconds: 0
                ),
            ])
        )
        let filtered = filter.filter(raw, at: 0)

        #expect(filtered.claims.recency.isEmpty)
        #expect(filter.retainedIdentities(ownedBy: [77]) == [identity(41)])
    }

    private func apply(
        _ claims  : SelectionClaimBatch,
        to selection: SeatTargetSelectionKit
    ) {
        for claim in claims.roles        { selection.declareRole(claim) }
        for claim in claims.parents      { selection.declareParent(claim) }
        for claim in claims.modals       { selection.declareModal(claim) }
        for claim in claims.visibilities { selection.observeVisibility(claim) }
        for claim in claims.recency      { selection.noteRecency(claim) }
    }

    private func surface(_ number: Int, visible: Bool) -> WindowSurface {
        WindowSurface(
            reference: WindowReference(
                identity: identity(number),
                frame   : CGRect(x: number, y: 20, width: 640, height: 480)
            ),
            level    : 0,
            isVisible: visible
        )
    }

    private func record(
        _ number : Int,
        role     : SurfaceRole,
        minimised: Bool?,
        modal    : Bool?,
        main     : Bool? = nil,
        focused  : Bool? = nil,
        parent   : Int? = nil,
        hidden   : Bool = false
    ) -> AccessibilitySurfaceRecord {
        AccessibilitySurfaceRecord(
            processID   : 77,
            windowNumber: number,
            role        : role,
            isMinimised : minimised,
            isModal     : modal,
            isMain      : main,
            isFocused   : focused,
            parentWindowNumber: parent,
            appIsHidden : hidden
        )
    }

    /// The attach panel, offline: the host application's standard window and the
    /// sheet it puts up for the open and save panel, both attested by the window
    /// server under the host's own process.
    ///
    /// What the reading used to carry is the standard window alone, because the
    /// sheet is not in `AXWindows` and only the focused slot reaches it. The
    /// server surface for it was there all along, which is why the seat logged
    /// the window and held it as not a member: a surface with no record of its
    /// own contributes no row and no claim, and membership is built from rows.
    @Test("a sheet reached only through the focused slot becomes a member with its own role")
    func hostedSheetBecomesAMember() throws {

        let withoutTheSheet = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [record(41, role: .document, minimised: false, modal: false, main: true)]
        )
        #expect(withoutTheSheet.inventory.rows.map(\.surface.reference.windowNumber) == [41],
                "the sheet's surface is read and carries nothing")
        #expect(withoutTheSheet.claims.roles.map(\.surface.windowNumber) == [41])

        // The same pass once the focused slot contributes its record.
        let withTheSheet = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, main: true),
                record(42, role: .dialog, minimised: false, modal: true,
                       focused: true, parent: 41),
            ]
        )
        #expect(withTheSheet.inventory.completeness.isQualified)
        #expect(withTheSheet.inventory.rows.map(\.surface.reference.windowNumber) == [41, 42])

        let sheet = try #require(withTheSheet.claims.roles.first { $0.surface.windowNumber == 42 })
        #expect(sheet.role == .dialog)
        #expect(sheet.provenance == .qualifiedRoleAttestation)

        // The identity is the window server's attested one, under the host
        // application: no second owner is introduced and nothing is adopted.
        #expect(sheet.surface == identity(42))
        #expect(sheet.surface.processID == 77)
        #expect(withTheSheet.inventory.rows.allSatisfy {
            $0.provenance == .windowServerAttestedIdentity
        })

        // And it is the host's window that the sheet hangs off, which is what
        // keeps it a surface of that application rather than a target of its own.
        let parent = try #require(withTheSheet.claims.parents.first)
        #expect(parent.child == identity(42))
        #expect(parent.parent == identity(41))
    }

    /// `AXModal` is required of a window and a surface that cannot say stays
    /// unknown. One role answers for itself: a sheet is modal to its parent by
    /// construction, and it does not expose the attribute.
    @Test("a sheet carries its own modality and every other window still has to say")
    func sheetModalityComesFromTheRole() {

        #expect(CrossCheckedSurfaceReader.modality(
            of: nil, roleName: kAXSheetRole as String) == true)

        // The protection, and the whole of it: an ordinary window with no
        // readable AXModal is exactly as unknown as it was.
        #expect(CrossCheckedSurfaceReader.modality(
            of: nil, roleName: kAXWindowRole as String) == nil)

        // A drawer sits beside its window and blocks nothing. It shares a branch
        // with a sheet for its empty subrole and for nothing else.
        #expect(CrossCheckedSurfaceReader.modality(
            of: nil, roleName: kAXDrawerRole as String) == nil)

        // The attribute wins wherever it answers, so a sheet that does say is
        // believed rather than overridden by its kind.
        #expect(CrossCheckedSurfaceReader.modality(
            of: kCFBooleanFalse, roleName: kAXSheetRole as String) == false)
        #expect(CrossCheckedSurfaceReader.modality(
            of: kCFBooleanTrue, roleName: kAXWindowRole as String) == true)
    }

    /// What the role answering changes downstream, which is the point: the panel
    /// becomes observable, and the window it is attached to stops being a
    /// candidate while it is up.
    @Test("a sheet that carries its modality is visible, and blocks the window it hangs off")
    func modalSheetIsObservableAndBlocksItsParent() throws {

        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), surface(42, visible: true)],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, main: true),
                // The sheet as the reading now produces it: modality from the
                // role, AXMinimized unread, which no rule reads for anything.
                record(42, role: .dialog, minimised: nil, modal: true,
                       focused: true, parent: 41),
            ]
        )

        let sheet = try #require(
            snapshot.claims.visibilities.first { $0.surface.windowNumber == 42 }
        )
        #expect(sheet.state == .visibleInteractive,
                "the surface the window server plainly shows is no longer uncertain")

        let modal = try #require(snapshot.claims.modals.first)
        #expect(modal.modal == identity(42))
        #expect(modal.scope == .window(identity(41)))
        #expect(modal.provenance == .qualifiedModalAttestation)
    }

    /// The mirror for the visibility rule itself, which this change does not
    /// touch: a window that could not say stays uncertain and keeps suspending.
    @Test("a window with no readable modality is still uncertain")
    func unreadableModalityIsStillUncertain() throws {

        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true)],
            accessibility: [record(41, role: .document, minimised: false, modal: nil)]
        )

        let reading = try #require(snapshot.claims.visibilities.first)
        #expect(reading.state == .uncertain)
        #expect(snapshot.claims.modals.isEmpty)
    }

    /// The mirror, so the exception is not a loosening: the two sources
    /// disagreeing about the owner is still no member, whatever the roles say.
    @Test("a window whose two sources name different processes is still refused")
    func disagreeingOwnersAreStillRefused() {

        let foreign = WindowSurface(
            reference: WindowReference(
                identity: WindowIdentity(
                    process: ProcessIdentity(
                        processID       : 25_763,
                        serialNumberHigh: 3,
                        serialNumberLow : 9
                    ),
                    windowNumber     : 42,
                    ownerConnectionID: 909
                ),
                frame: CGRect(x: 42, y: 20, width: 640, height: 480)
            ),
            level    : 0,
            isVisible: true
        )
        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer : [surface(41, visible: true), foreign],
            accessibility: [
                record(41, role: .document, minimised: false, modal: false, main: true),
                record(42, role: .dialog, minimised: false, modal: true, focused: true),
            ]
        )

        #expect(snapshot.inventory.rows.map(\.surface.reference.windowNumber) == [41],
                "the window server names another process, so there is nothing to join")
        #expect(snapshot.claims.roles.map(\.surface.windowNumber) == [41])
        #expect(!snapshot.inventory.completeness.isQualified,
                "and an accessibility row with no attested counterpart still refuses completeness")
    }

    private func identity(_ number: Int) -> WindowIdentity {
        WindowIdentity(
            process: ProcessIdentity(
                processID       : 77,
                serialNumberHigh: 3,
                serialNumberLow : 9
            ),
            windowNumber     : number,
            ownerConnectionID: 101
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
