//
//  CrossCheckedSurfaceReaderTests.swift
//  AgentSeatKit
//
//  Created by OpenAI Codex on 16/09/2026.
//

import ApplicationServices
import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

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

    @Test("an AXUnknown top-level movable raiseable window is an interactive panel")
    func operableUnknownWindowIsSelectable() {
        let role = CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: "AXUnknown",
            positionIsSettable: true,
            actions: [kAXRaiseAction as String]
        )

        #expect(role == .interactivePanel)
    }

    @Test("an AXUnknown window without both operability traits has no role")
    func unknownDecorationIsNotPromoted() {
        #expect(CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: "AXUnknown",
            positionIsSettable: false,
            actions: [kAXRaiseAction as String]
        ) == nil)
        #expect(CrossCheckedSurfaceReader.role(
            named: kAXWindowRole as String,
            subrole: "AXUnknown",
            positionIsSettable: true,
            actions: []
        ) == nil)
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
