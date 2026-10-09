//
//  SurfaceRestitution.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// RestitutionBlock is one reason a surface is not back where it belongs. Each
/// case leaves the window exactly where it is: there is no case for closing a
/// document and none for picking a display nobody chose.
nonisolated package enum RestitutionBlock: Sendable, Equatable, Error {

    /// Nothing was assigned, so nothing was given back. A rejection before any
    /// effect, told apart from a return that started and did not finish.
    case notAssigned

    /// A pre-existing window whose original display is gone, or whose original
    /// frame no longer fits it, and for which the consumer chose nothing. The
    /// window stays where it is until the consumer chooses.
    case originalPlaceGone(windowNumber: Int)

    /// A window born during the assignment, for which the consumer has not
    /// chosen a physical display. It has no place in the User Seat to go back
    /// to, and this kit does not invent one.
    case noDestinationChosen(windowNumber: Int)

    /// The display the consumer chose is not in the online set.
    case chosenDisplayOffline(windowNumber: Int, displayID: CGDirectDisplayID)

    /// The chosen display's bounds cannot carry a window frame.
    case destinationUnusable(windowNumber: Int)

    /// The effector refused, before any effect, with its reason.
    case effectRefused(windowNumber: Int, refusal: EffectRefusal)
}

/// SurfaceReturn is one requested placement back in the User Seat, with the
/// origin that decided the destination so a report can say why it is there.
nonisolated package struct SurfaceReturn: Sendable, Equatable {

    package let identity        : WindowIdentity
    package let origin          : SurfaceOrigin
    package let destinationFrame: CGRect

    package var windowNumber: Int { identity.windowNumber }

    package init(identity: WindowIdentity, origin: SurfaceOrigin, destinationFrame: CGRect) {
        self.identity         = identity
        self.origin           = origin
        self.destinationFrame = destinationFrame
    }
}

/// RestitutionPlan is where each surface has to go, and the surfaces for which
/// no valid destination exists.
nonisolated package struct RestitutionPlan: Sendable, Equatable {

    package let returns: [SurfaceReturn]
    package let blocks : [RestitutionBlock]

    package init(returns: [SurfaceReturn], blocks: [RestitutionBlock]) {
        self.returns = returns
        self.blocks  = blocks
    }
}

/// RestitutionOutcome is the result of one attempt to give the windows back.
///
/// The three failures the consumer has to tell apart are separate here: a
/// rejection before any effect is `blocks == [.notAssigned]`, partial effects
/// are the issued returns next to the remaining blocks, and an incomplete
/// restitution is any outcome whose blocks are not empty. None of them is a
/// success, and `issuedReturns` is delivery and not proof.
nonisolated package struct RestitutionOutcome: Sendable, Equatable {

    /// Return requests handed to the effector. They still need two agreeing
    /// readings through `confirm` before the window counts as back.
    package let issuedReturns: [SurfaceReturn]

    package let blocks: [RestitutionBlock]

    /// Always true from the first call: the authority to send input ends before
    /// any window is moved back, and no cleanup step restores it.
    package let inputAuthorityIsRevoked: Bool

    /// True while a surface still has nowhere valid to go or has not been
    /// verified back. The Virtual Display those windows are on stays alive: a
    /// display destroyed under them would move them somewhere nobody chose.
    package let retainsVirtualDisplay: Bool

    /// True only when every member was verified back in the User Seat.
    package var isComplete: Bool { blocks.isEmpty && !retainsVirtualDisplay }

    package init(
        issuedReturns          : [SurfaceReturn],
        blocks                 : [RestitutionBlock],
        inputAuthorityIsRevoked: Bool,
        retainsVirtualDisplay  : Bool
    ) {
        self.issuedReturns           = issuedReturns
        self.blocks                  = blocks
        self.inputAuthorityIsRevoked = inputAuthorityIsRevoked
        self.retainsVirtualDisplay   = retainsVirtualDisplay
    }
}

/// SurfaceRestitution owns the return half of an assignment: where each surface
/// has to go, which ones have nowhere valid to go, and which ones two agreeing
/// readings have put back.
///
/// ## Two origins, two destinations
///
/// A window that was already open when the application was handed over goes back
/// to the frame it had, on the display that held it, when that place is still
/// valid. A window born during the assignment has no such place, so the consumer
/// names a physical display and the window is placed visibly on it. When neither
/// is available the surface stays where it is and the outcome says so: there is
/// no arbitrary display and no closing of documents.
///
/// ## It survives the end of the assignment
///
/// The assignment ends when the consumer releases it, and the windows can still
/// be out there. This value therefore holds the pending surfaces after the
/// lifecycle has ended, as a cleanup obligation that carries no input authority
/// and no Turn.
nonisolated package struct SurfaceRestitution: Sendable {

    /// PendingSurface is what the return needs after the inventory is gone: the
    /// attested identity, where the window came from, and the destination the
    /// last plan chose for it.
    nonisolated package struct PendingSurface: Sendable, Equatable {

        package let identity         : WindowIdentity
        package let origin           : SurfaceOrigin
        package let originalFrame    : CGRect
        package let originalDisplayID: CGDirectDisplayID?

        /// The desktop the surface was on when it was first attributed, nil when
        /// it was not read. A return that can verify desktops checks against it.
        package let originalSpaceID: Int?

        /// The destination of the last issued request, nil while none was.
        package fileprivate(set) var destinationFrame: CGRect?

        /// The previous reading, kept so that two agreeing readings, and not
        /// one, are what declare a window back.
        package fileprivate(set) var lastObservedFrame: CGRect?

        package init(
            identity         : WindowIdentity,
            origin           : SurfaceOrigin,
            originalFrame    : CGRect,
            originalDisplayID: CGDirectDisplayID?,
            originalSpaceID  : Int? = nil
        ) {
            self.identity          = identity
            self.origin            = origin
            self.originalFrame     = originalFrame
            self.originalDisplayID = originalDisplayID
            self.originalSpaceID   = originalSpaceID
            self.destinationFrame  = nil
            self.lastObservedFrame = nil
        }
    }

    package private(set) var pending: [Int: PendingSurface] = [:]

    /// Window IDs verified back in the User Seat by two agreeing readings.
    package private(set) var returned: Set<Int> = []

    package init() {}

    package var outstanding: [Int] { pending.keys.sorted() }

    /// Takes the members of an ending assignment as the surfaces to give back.
    /// Called once, when the release starts, because after that the inventory
    /// stops being updated and these windows are a cleanup obligation.
    package mutating func begin(members: [AssignedSurface]) {
        for member in members where pending[member.windowNumber] == nil {
            pending[member.windowNumber] = PendingSurface(
                identity         : member.identity,
                origin           : member.origin,
                originalFrame    : member.originalFrame,
                originalDisplayID: member.originalDisplayID,
                originalSpaceID  : member.originalSpaceID
            )
        }
    }

    /// Decides where each outstanding surface goes, given the displays that are
    /// online now and the destinations the consumer chose by Window ID.
    package func plan(
        chosenDisplays: [Int: CGDirectDisplayID],
        displays      : [CGDirectDisplayID: CGRect]
    ) -> RestitutionPlan {

        var returns: [SurfaceReturn]      = []
        var blocks : [RestitutionBlock]   = []

        for number in pending.keys.sorted() {
            guard let surface = pending[number] else { continue }
            switch destination(for: surface, chosenDisplays: chosenDisplays, displays: displays) {
                case .success(let frame):
                    returns.append(
                        SurfaceReturn(
                            identity        : surface.identity,
                            origin          : surface.origin,
                            destinationFrame: frame
                        )
                    )
                case .failure(let block):
                    blocks.append(block)
            }
        }
        return RestitutionPlan(returns: returns, blocks: blocks)
    }

    /// Records the destination a request was issued for, so the verification
    /// compares readings against what was actually asked.
    package mutating func noteIssued(_ windowNumber: Int, destination: CGRect) {
        pending[windowNumber]?.destinationFrame  = destination
        pending[windowNumber]?.lastObservedFrame = nil
    }

    /// Folds one reading of the returning windows in and answers the Window IDs
    /// that two agreeing readings have now put at their destination.
    ///
    /// One reading is a sighting: a window publishes its new frame before it has
    /// settled, so a single agreement would declare a return that is still in
    /// flight. A surface for which no request was issued is skipped rather than
    /// declared back by being in the right place already.
    @discardableResult
    package mutating func confirm(observations: [Int: CGRect]) -> [Int] {

        var verified: [Int] = []
        for (number, frame) in observations.sorted(by: { $0.key < $1.key }) {
            guard let surface = pending[number], let destination = surface.destinationFrame else { continue }

            let agreesNow = VirtualWindowPlacementCheck.framesMatch(frame, destination)
            let agreedBefore = surface.lastObservedFrame.map {
                VirtualWindowPlacementCheck.framesMatch($0, destination)
            } ?? false

            guard agreesNow, agreedBefore else {
                pending[number]?.lastObservedFrame = frame
                continue
            }
            pending[number] = nil
            returned.insert(number)
            verified.append(number)
        }
        return verified
    }

    /// The destination for one surface, or the reason it has none.
    ///
    /// The original place is preferred and is checked rather than assumed: the
    /// display that held the window has to be online now and its bounds have to
    /// still contain that exact frame. When it does not, the consumer's chosen
    /// display is the only other answer, and its absence is a block.
    private func destination(
        for surface   : PendingSurface,
        chosenDisplays: [Int: CGDirectDisplayID],
        displays      : [CGDirectDisplayID: CGRect]
    ) -> Result<CGRect, RestitutionBlock> {

        let number = surface.identity.windowNumber

        if surface.origin == .preexisting,
           let original = surface.originalDisplayID,
           let bounds   = displays[original],
           SurfacePlacement.isContained(surface.originalFrame, within: bounds) {
            return .success(surface.originalFrame)
        }

        guard let chosen = chosenDisplays[number] else {
            return .failure(
                surface.origin == .preexisting
                    ? .originalPlaceGone(windowNumber: number)
                    : .noDestinationChosen(windowNumber: number)
            )
        }
        guard let bounds = displays[chosen] else {
            return .failure(.chosenDisplayOffline(windowNumber: number, displayID: chosen))
        }
        guard let frame = SurfacePlacement.visibleFrame(forSizeOf: surface.originalFrame, on: bounds) else {
            return .failure(.destinationUnusable(windowNumber: number))
        }
        return .success(frame)
    }
}
