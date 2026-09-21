//
//  SurfaceEffecting.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// EffectorQualification says whether an adapter is allowed to act on a surface
/// of an assigned application on the running system.
///
/// It is a value on the adapter rather than a comment next to it because the
/// nucleus refuses to plan around an unqualified adapter, and a reader has to be
/// able to see which one it is holding. Qualification is evidence about a
/// primitive on a build, produced by a separate qualification step; nothing in
/// this package promotes itself.
nonisolated package enum EffectorQualification: Sendable, Equatable {

    /// A qualified primitive backs the effect, named so a report can say which.
    case qualified(primitive: String)

    /// The adapter exists and may not act. The reason is structured enough for a
    /// consumer to tell "not qualified yet" from "broken".
    case notQualified(reason: String)

    package var mayAct: Bool {
        if case .qualified = self { return true }
        return false
    }
}

/// EffectRefusal is why an effect was not performed, before anything happened.
/// A refusal is a fact the consumer can act on, never a silent no-op and never a
/// string in a log.
nonisolated package enum EffectRefusal: Sendable, Equatable, Error {

    /// No qualified adapter backs this effect on this build.
    case adapterNotQualified(reason: String)

    /// The surface was not attributed to the assigned application, so the seat
    /// has no business moving it.
    case surfaceNotAttributed(windowNumber: Int)

    /// The destination is not a rectangle a window can be placed in.
    case destinationUnusable(reason: String)

    /// The identity offered is not attested, so the effect would be aimed at a
    /// Window ID rather than at a window.
    case identityNotAttested
}

/// EffectDelivery is what an effector answers. It says whether the request left,
/// never whether it worked: proof that a window is where the seat asked for it
/// comes from two agreeing readings, and an adapter that returned no error has
/// not supplied one.
nonisolated package enum EffectDelivery: Sendable, Equatable {

    /// The request was handed to the primitive. Its effect is still unproven.
    case issued

    case refused(EffectRefusal)
}

/// SurfaceEffecting is the one boundary through which the assignment nucleus
/// changes the world: it asks for an attested window to be placed at a frame.
///
/// The role lives in the core and the adapters live outside it, so the nucleus
/// can be exercised whole against a controlled double and still make no system
/// call. A conformer owns its primitives and their lifetime; the nucleus borrows
/// it for the length of the assignment and never stores a reading from it.
///
/// A conformer must refuse rather than act when it is not qualified, and must
/// not report `issued` for a call whose return value it did not check.
package protocol SurfaceEffecting {

    var qualification: EffectorQualification { get }

    /// Requests that the attested window be placed at `frame`. The answer is a
    /// delivery, not a placement: the caller verifies with fresh readings.
    func requestMove(of identity: WindowIdentity, to frame: CGRect) -> EffectDelivery
}

/// UnqualifiedSurfaceEffector refuses every effect with a structured reason, and
/// it is the only conformer this package ships.
///
/// It is deliberate, not a placeholder. No adapter for moving the surfaces of an
/// assigned application has been qualified on this build, so the composition
/// default has to fail closed: an effector that "worked" because a private call
/// returned no error would be exactly the unqualified promotion the kit forbids.
/// A qualified adapter replaces it at composition once its primitives have their
/// own evidence.
nonisolated package struct UnqualifiedSurfaceEffector: SurfaceEffecting, Sendable {

    package static let defaultReason =
        "No surface effect adapter has been qualified for the assigned application path on this build"

    package let reason: String

    package init(reason: String = UnqualifiedSurfaceEffector.defaultReason) {
        self.reason = reason
    }

    package var qualification: EffectorQualification { .notQualified(reason: reason) }

    package func requestMove(of _: WindowIdentity, to _: CGRect) -> EffectDelivery {
        .refused(.adapterNotQualified(reason: reason))
    }
}
