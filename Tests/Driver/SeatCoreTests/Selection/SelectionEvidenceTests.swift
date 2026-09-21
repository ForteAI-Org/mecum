//
//  SelectionEvidenceTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

@testable import SeatCore
import Testing

/// What each source of evidence is allowed to decide, and what this build has
/// qualified natively.
///
/// The second half is the important one: every native verdict is `notRun`, and
/// no suite in this package changes that. A controlled double handing in a
/// qualified provenance exercises the algorithm downstream of a signal; it is
/// not evidence that the signal can be read on macOS.
@Suite("The evidence behind a selection")
struct SelectionEvidenceTests {

    @Test("An attested identity carries no selection conclusion at all")
    func attestedIdentityProvesOnlyIdentity() {

        let identity = SelectionProvenance.windowServerAttestedIdentity

        #expect(SelectionConclusion.allCases.allSatisfy { !identity.attests($0) })
        #expect(!identity.isQualifiedShape)
    }

    @Test("A level, a title, a PID, the member order, a frame comparison, the global focus and the kit's own raises carry nothing")
    func unqualifiedSourcesCarryNothing() {

        let unqualified: [SelectionProvenance] = [
            .onScreenWindowList,
            .windowLevel,
            .windowTitle,
            .processIdentifier,
            .memberOrderByWindowID,
            .geometryComparison,
            .globalApplicationFocus,
            .kitIssuedPlacement,
        ]

        for provenance in unqualified {
            #expect(SelectionConclusion.allCases.allSatisfy { !provenance.attests($0) })
        }
    }

    @Test("Each qualified shape carries exactly one conclusion")
    func eachQualifiedShapeCarriesOneConclusion() {

        for provenance in SelectionProvenance.allCases where provenance.isQualifiedShape {
            let carried = SelectionConclusion.allCases.filter { provenance.attests($0) }
            #expect(carried.count == 1, "\(provenance.rawValue) carries \(carried)")
        }
    }

    @Test("Only three reported events qualify as recency")
    func threeSignalsQualify() {

        let qualifying = RecencySignal.allCases.filter(\.qualifiesRecency)

        #expect(qualifying == [.appeared, .reappeared, .returnedToFront])
    }

    @Test("The report covers every conclusion and claims no native provider")
    func noNativeSignalIsQualified() {

        let report = SelectionEvidenceReport.current

        #expect(report.rows.map(\.conclusion) == SelectionConclusion.allCases)
        #expect(report.conclusionsWithoutNativeProvider == SelectionConclusion.allCases)
        #expect(report.rows.allSatisfy { $0.nativeVerdict == .notRun })
        #expect(report.rows.allSatisfy { !$0.offlineScope.isEmpty })
    }

    @Test("Parentage, the origin of a raise and the helper relation are reported in their own right")
    func parentageRaiseAndHelperAreSeparateRows() {

        let report = SelectionEvidenceReport.current

        #expect(report.row(for: .parentRelation)?.acceptedProvenance == .qualifiedParentAttestation)
        #expect(report.row(for: .raiseProvenance)?.acceptedProvenance == .qualifiedRaiseAttribution)
        #expect(report.row(for: .helperRelation)?.acceptedProvenance == nil)
        #expect(report.row(for: .helperRelation)?.nativeVerdict == .notRun)
    }

    @Test("The shipped assignment effector is still the unqualified one")
    func theCompositionActivatesNoNativeAdapter() {

        let kit       = SeatAssignmentKit()
        let selection = SeatTargetSelectionKit(assignment: kit)

        #expect(!kit.effectorQualification.mayAct)
        #expect(selection.evidenceReport.conclusionsWithoutNativeProvider.count
            == SelectionConclusion.allCases.count)
    }
}
