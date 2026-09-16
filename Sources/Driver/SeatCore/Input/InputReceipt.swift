//
//  InputReceipt.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// InputReceipt is what a send returns: proof of delivery, never proof of
/// effect. Every field is structured, because a receipt is read by a report, by
/// a test and by a budget check, and none of them can parse a sentence. Whether
/// the input did anything is answered separately, by `EffectConfirmation`.
public struct InputReceipt: Sendable, Equatable {

    /// How many events were posted, routed ones included.
    public let eventCount: Int

    /// Where the events went and by which call.
    public let route: InputRoute

    /// What was done to the target's own state before the Command, and undone
    /// after it.
    public let preparation: Preparation

    /// How long the send took, settle apart.
    public let timing: InputTiming

    /// The complete temporal account of this Command. A production
    /// `InputDriver` always supplies one. Nil remains available to test doubles
    /// and third-party `CommandSending` witnesses that predate tracing.
    public let trace: InputCommandTrace?

    /// What the seat saw around the action, when a seat was watching.
    public let observation: SeatObservation?

    /// True when the facility acted on a macOS build the Ledger does not
    /// validate. The consumer decides what to do with that; the kit only marks
    /// it, on the receipt and on the event stream.
    public let unvalidatedBuild: Bool

    /// What happened when the driver undid the Preparation after posting. A
    /// failure is carried on the Receipt because the events already went out;
    /// throwing it as a delivery failure would invite an unsafe replay.
    public let cleanup: InputCleanupResult

    /// The modifiers this session still holds on the target process after this
    /// Command, every holder of that process included.
    ///
    /// It is an observation and not a promise, like everything else here: it
    /// says what the kit believes it is holding, which under the default
    /// modifier policy is bookkeeping that no target was ever told about. A
    /// non-empty value after a Command that was not a `.down` means another
    /// Turn is holding something on the same process.
    public let heldAfter: Modifiers

    /// How much text this Command carried, in the unit that Command counts in,
    /// or nil when it carried none.
    ///
    /// It is here because `eventCount` is not it and must never be read as it:
    /// `.insertText` is two events at any length, so a caller inferring how much
    /// text arrived from the event count would be wrong by three orders of
    /// magnitude. This says what was **posted**, which like everything else on
    /// a Receipt is delivery and not effect.
    public let textMeasure: TextMeasure?

    /// The `KeyboardLayout.generation` that resolved this Command, or nil when
    /// no layout was consulted.
    ///
    /// Nil is the ordinary answer: a Command built from a virtual key or from a
    /// key position never asks what layout is installed, and a mouse Command
    /// never does either. A consumer comparing this across two receipts sees
    /// the person changing keyboard layout without the kit having to watch for
    /// it.
    public let layoutGeneration: UInt64?

    /// True when the Preparation may still be applied. Kept as the compatible
    /// spelling for existing consumers; `cleanup` carries the richer evidence.
    public var hasUnrestoredPreparation: Bool { cleanup.needsRecovery }

    public init(
        eventCount              : Int,
        route                   : InputRoute,
        preparation             : Preparation = .none,
        timing                  : InputTiming = InputTiming(postingNanoseconds: 0),
        trace                   : InputCommandTrace? = nil,
        observation             : SeatObservation? = nil,
        unvalidatedBuild        : Bool = false,
        cleanup                 : InputCleanupResult? = nil,
        heldAfter               : Modifiers = [],
        layoutGeneration        : UInt64? = nil,
        textMeasure             : TextMeasure? = nil,
        hasUnrestoredPreparation: Bool = false
    ) {
        self.eventCount               = eventCount
        self.route                    = route
        self.preparation              = preparation
        self.timing                   = timing
        self.trace                    = trace
        self.observation              = observation
        self.unvalidatedBuild = unvalidatedBuild
        self.heldAfter        = heldAfter
        self.layoutGeneration = layoutGeneration
        self.textMeasure      = textMeasure
        self.cleanup          = cleanup ?? Self.compatibleCleanup(
            preparation             : preparation,
            hasUnrestoredPreparation: hasUnrestoredPreparation
        )
    }

    /// The same receipt with a seat's observation attached, which is how the
    /// field stops being always nil: the driver posts events and makes no
    /// observation, the seat watches the User Seat and has one.
    public func attaching(_ observation: SeatObservation?) -> InputReceipt {
        InputReceipt(
            eventCount              : eventCount,
            route                   : route,
            preparation             : preparation,
            timing                  : timing,
            trace                   : trace,
            observation             : observation,
            unvalidatedBuild: unvalidatedBuild,
            cleanup         : cleanup,
            heldAfter       : heldAfter,
            layoutGeneration: layoutGeneration,
            textMeasure     : textMeasure
        )
    }

    /// replacingTrace keeps every delivery fact intact while the driver adds
    /// restoration and completion timing after the posting receipt exists.
    public func replacingTrace(_ trace: InputCommandTrace) -> InputReceipt {
        InputReceipt(
            eventCount              : eventCount,
            route                   : route,
            preparation             : preparation,
            timing                  : timing,
            trace                   : trace,
            observation             : observation,
            unvalidatedBuild: unvalidatedBuild,
            cleanup         : cleanup,
            heldAfter       : heldAfter,
            layoutGeneration: layoutGeneration,
            textMeasure     : textMeasure
        )
    }

    /// replacingLayoutGeneration records which keyboard layout reading resolved
    /// this Command. The driver cannot know it: resolution happens above, in
    /// the session, and only for a Shortcut written as a character.
    public func replacingLayoutGeneration(_ layoutGeneration: UInt64?) -> InputReceipt {
        InputReceipt(
            eventCount      : eventCount,
            route           : route,
            preparation     : preparation,
            timing          : timing,
            trace           : trace,
            observation     : observation,
            unvalidatedBuild: unvalidatedBuild,
            cleanup         : cleanup,
            heldAfter       : heldAfter,
            layoutGeneration: layoutGeneration,
            textMeasure     : textMeasure
        )
    }

    /// replacingCleanup keeps the delivery facts intact while the driver adds
    /// the result of the restore that necessarily happens after posting.
    public func replacingCleanup(_ cleanup: InputCleanupResult) -> InputReceipt {
        InputReceipt(
            eventCount      : eventCount,
            route           : route,
            preparation     : preparation,
            timing          : timing,
            trace           : trace,
            observation     : observation,
            unvalidatedBuild: unvalidatedBuild,
            cleanup         : cleanup,
            heldAfter       : heldAfter,
            layoutGeneration: layoutGeneration,
            textMeasure     : textMeasure
        )
    }

    /// Maps the former boolean initializer onto the structured cleanup result.
    /// An old witness cannot supply a refusal code, so that field remains nil.
    private static func compatibleCleanup(
        preparation             : Preparation,
        hasUnrestoredPreparation: Bool
    ) -> InputCleanupResult {
        if hasUnrestoredPreparation { return .failed(code: nil) }
        return preparation == .none ? .notRequired : .succeeded
    }
}
