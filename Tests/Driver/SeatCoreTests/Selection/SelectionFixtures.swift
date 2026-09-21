//
//  SelectionFixtures.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
@testable import SeatCore

/// Written claims for the selection suites, built on the same synthetic values
/// the assignment suites use.
///
/// Every role, visibility, parentage, modal relation and qualified event is
/// written down here and handed to the same Sources logic. A claim carrying
/// `qualifiedRoleAttestation`, `qualifiedModalAttestation`,
/// `qualifiedFrontOrderAttestation` or `qualifiedRaiseAttribution` exercises the
/// algorithm that runs once such an adapter has been qualified. It certifies no
/// adapter: no provider on this build produces any of those provenances, and no
/// suite here opens a window, raises one, reads a role or observes a focus.
enum SelectionFixtures {

    typealias Assignment = AssignmentFixtures

    static func identity(_ windowNumber: Int) -> WindowIdentity {
        Assignment.identity(windowNumber)
    }

    static func role(
        _ windowNumber: Int,
        _ role        : SurfaceRole,
        provenance    : SelectionProvenance = .qualifiedRoleAttestation
    ) -> SurfaceRoleClaim {

        SurfaceRoleClaim(surface: identity(windowNumber), role: role, provenance: provenance)
    }

    static func visibility(
        _ windowNumber: Int,
        _ state       : SurfaceVisibility,
        provenance    : SelectionProvenance = .qualifiedVisibilityAttestation
    ) -> SurfaceVisibilityClaim {

        SurfaceVisibilityClaim(surface: identity(windowNumber), state: state, provenance: provenance)
    }

    static func parent(
        _ child       : Int,
        of parent     : Int,
        provenance    : SelectionProvenance = .qualifiedParentAttestation
    ) -> SurfaceParentClaim {

        SurfaceParentClaim(
            child     : identity(child),
            parent    : identity(parent),
            provenance: provenance
        )
    }

    /// A modal relation over one window, or over the whole application when
    /// `window` is nil.
    static func modal(
        _ windowNumber: Int,
        over window   : Int?,
        provenance    : SelectionProvenance = .qualifiedModalAttestation
    ) -> ModalRelationClaim {

        ModalRelationClaim(
            modal     : identity(windowNumber),
            scope     : window.map { ModalScope.window(identity($0)) } ?? .application,
            provenance: provenance
        )
    }

    /// One reported event about a surface, qualified unless a suite says
    /// otherwise.
    static func event(
        _ windowNumber: Int,
        _ signal      : RecencySignal = .appeared,
        at instant    : UInt64,
        provenance    : SelectionProvenance = .qualifiedFrontOrderAttestation,
        origin        : RecencyClaim.Origin = .application(provenance: .qualifiedRaiseAttribution)
    ) -> RecencyClaim {

        RecencyClaim(
            surface              : identity(windowNumber),
            signal               : signal,
            provenance           : provenance,
            origin               : origin,
            observedAtNanoseconds: instant
        )
    }

    static func observation(
        _ windowNumber: Int,
        generation    : UInt64,
        frame         : CGRect = AssignmentFixtures.contained
    ) -> TargetObservationClaim {

        TargetObservationClaim(
            surface            : identity(windowNumber),
            selectionGeneration: generation,
            frame              : frame
        )
    }

    /// A core that knows the given windows as visible documents, which is the
    /// ordinary starting point every policy case varies from.
    static func core(documents: [Int], members: [AssignedSurface]) -> TargetSelectionCore {

        var core = TargetSelectionCore()
        for windowNumber in documents {
            core.declareRole(role(windowNumber, .document), members: members)
            core.observeVisibility(visibility(windowNumber, .visibleInteractive), members: members)
        }
        return core
    }
}

/// MemberFolder drives a real `AssignedSurfaceInventory` from written readings,
/// so the selection suites compose with the committed membership model instead
/// of a second one built for the tests.
struct MemberFolder {

    private var inventory  = AssignedSurfaceInventory()
    private let attributor = SurfaceAttributor(instance: AssignmentFixtures.target)
    private var clock      : UInt64 = 0

    init() {}

    var members: [AssignedSurface] { inventory.members }

    /// Folds one reading of these windows, at the frame given.
    @discardableResult
    mutating func fold(
        _ windowNumbers: [Int],
        at frame       : CGRect = AssignmentFixtures.contained
    ) -> [AssignedSurface] {

        clock &+= 10_000_000
        inventory.fold(
            AssignmentFixtures.reading(windowNumbers.map { AssignmentFixtures.row($0, at: frame) }),
            attributor: attributor,
            within    : AssignmentFixtures.virtual,
            at        : clock
        )
        return inventory.members
    }

    /// Folds the same reading twice, which is what makes the members verified.
    @discardableResult
    mutating func settle(
        _ windowNumbers: [Int],
        at frame       : CGRect = AssignmentFixtures.contained
    ) -> [AssignedSurface] {

        fold(windowNumbers, at: frame)
        return fold(windowNumbers, at: frame)
    }
}
