//
//  InputPlatform.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore

/// InputPlatform is the preparation and pacing policy for one family of target
/// applications. **The route is not part of it**: every family measured so far
/// accepts the same one, Preparation plus `CGEventPostToPid` of events the
/// driver builds, and putting the route back in the protocol would make the
/// private primitives public again.
///
/// What a platform decides is therefore small on purpose:
///
/// - **when to prepare**, the only ingredient measured to change an outcome:
///   a Chromium renderer refuses a click from a window it does
///   not consider key, and an AppKit target accepts one either way;
/// - **how long to wait** for the target to apply that preparation, per Command,
///   because one Command was measured to need five times what the others do;
/// - **how fast a drag may be**, because a background app drops a drag that
///   arrives faster than a hand could produce it;
/// - **one escape hatch**, `decorate`, for a family nobody has measured yet.
///
/// It is public so a consumer can add Flutter, Qt or a game engine without
/// touching the kit. The two implementations the kit ships are the two that
/// were measured; a platform a consumer writes has no live test here.
nonisolated public protocol InputPlatform: Sendable {

    /// Whether this Command needs the target's own AppKit state prepared
    /// before it is posted, and undone after.
    func preparation(for command: InputCommand) -> Preparation

    /// How long to wait between the Preparation and the first event, for this
    /// Command. It is the largest cost left on the warm path, so it is the
    /// platform's answer and not a constant; the default below carries its own
    /// measurement.
    ///
    /// It takes the Command for the same reason `preparation(for:)` does: one
    /// family was measured to need five times the wait for one Command and the
    /// default for all the others, and a single number for the platform would
    /// have made every click pay for it.
    func preparationSettle(for command: InputCommand) -> Duration

    /// The pacing of a drag: the pause after the opening move, after the press
    /// and after every step.
    var dragPacing: DragPacing { get }

    /// A last field on an event, for a target family that needs one. The
    /// default does nothing, and both platforms the kit ships keep it that way:
    /// the Chromium stamping this hook was kept for turned out to change no
    /// outcome.
    func decorate(_ event: CGEvent, for command: InputCommand)
}

nonisolated extension InputPlatform {

    /// Both target families applied the preparation within 20 ms in every
    /// measured case, at 20, 40 and 80 ms; the default is the smallest that
    /// worked plus half again.
    public func preparationSettle(for command: InputCommand) -> Duration {
        .milliseconds(30)
    }

    /// The pacing measured on the fixture and on Chromium renderers.
    public var dragPacing: DragPacing { .realistic }

    /// Nothing, which is what both shipped platforms need.
    public func decorate(_ event: CGEvent, for command: InputCommand) {}
}

nonisolated extension InputPlatform where Self == ChromiumPlatform {

    /// The platform for a consumer that does not know what the target is built
    /// with, and the default of `adopt`. It is `ChromiumPlatform` because that
    /// policy is the safe superset: an AppKit target accepts a prepared mouse
    /// Command too, and the only cost is the Preparation itself.
    public static var universal: ChromiumPlatform { ChromiumPlatform() }
}
