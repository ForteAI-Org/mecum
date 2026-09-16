//
//  FlagsChangedRecord.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics

/// FlagsChangedRecordCheck is what the running system answered when asked
/// whether a modifier transition event encodes the way the rest of the table
/// does.
///
/// It is its own check and not another field on `RecordLayoutCheck` because the
/// two run at different moments for different reasons. The cross-validation
/// runs at every Facility start and costs six loads; this runs once, in the
/// compatibility suite, and it is a question about one event type nobody has
/// posted yet.
nonisolated public struct FlagsChangedRecordCheck: Sendable, Equatable {

    /// Whether writing `.flagsChanged` into a keyboard event's type stuck.
    ///
    /// CoreGraphics offers no constructor for a modifier transition, so the
    /// only way to build one is to make a keyboard event and change its type.
    /// If that assignment were silently ignored the rest of this check would be
    /// measuring a key down and calling it a transition.
    public let eventTypeHeld: Bool

    /// What the record declared at 0x04, or nil when no record was reachable.
    public let declaredLength: UInt32?

    /// The byte actually found at 0x08.
    public let observedTypeByte: UInt8?

    /// The byte `RecordLayout.typeByte(of:)` says should be there, which for
    /// `.flagsChanged` is 0x0C.
    public let expectedTypeByte: UInt8?

    /// The first thing that went wrong, structured. Nil when everything held.
    public let failure: SystemFailure?

    /// True only when the type assignment held, the record had the declared
    /// length, and the byte at 0x08 was the one the rule predicts.
    public var passed: Bool {
        failure == nil
            && eventTypeHeld
            && declaredLength == RecordLayout.declaredLength
            && observedTypeByte != nil
            && observedTypeByte == expectedTypeByte
    }

    public init(
        eventTypeHeld   : Bool,
        declaredLength  : UInt32?,
        observedTypeByte: UInt8?,
        expectedTypeByte: UInt8?,
        failure         : SystemFailure?
    ) {
        self.eventTypeHeld    = eventTypeHeld
        self.declaredLength   = declaredLength
        self.observedTypeByte = observedTypeByte
        self.expectedTypeByte = expectedTypeByte
        self.failure          = failure
    }
}

nonisolated extension RecordLayout {

    /// Asks the running system whether a modifier transition event encodes its
    /// type at 0x08 the way every other event type does.
    ///
    /// `typeByte(of:)` states the rule for the whole table, but a rule is not a
    /// verification: the bytes actually read back out of records so far are
    /// 0x01 to 0x04, 0x0A, 0x0B and 0x16, and `.flagsChanged` is none of them.
    /// Until this answers, a Facility that would post a transition refuses,
    /// which is ADR 0001 applied to a behaviour of a public API rather than to
    /// a private symbol.
    ///
    /// Nothing is posted. One event is created, mutated and thrown away.
    public static func verifyFlagsChangedRecord(
        using table: SymbolTable = .shared
    ) -> FlagsChangedRecordCheck {

        func failed(_ failure: SystemFailure, typeHeld: Bool = false) -> FlagsChangedRecordCheck {
            FlagsChangedRecordCheck(
                eventTypeHeld   : typeHeld,
                declaredLength  : nil,
                observedTypeByte: nil,
                expectedTypeByte: typeByte(of: .flagsChanged),
                failure         : failure
            )
        }

        guard
            let recordPointer = table.function(
                .eventRecordPointer,
                as: SymbolABI.EventRecordPointer.self
            ),
            let source = CGEventSource(stateID: .privateState),
            // The Command key's own virtual key, because a transition event
            // carries the keycode of the modifier that moved.
            let event = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
        else {
            return failed(.eventRecordUnavailable)
        }

        event.type = .flagsChanged
        let typeHeld = event.type == .flagsChanged

        let eventPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(event).toOpaque())
        guard let record = recordPointer(UnsafeRawPointer(eventPointer)) else {
            return failed(.eventRecordUnavailable, typeHeld: typeHeld)
        }

        let declared: UInt32
        do {
            declared = try validateDeclaredLength(of: record)
        } catch let failure as SystemFailure {
            return failed(failure, typeHeld: typeHeld)
        } catch {
            return failed(.eventRecordUnavailable, typeHeld: typeHeld)
        }

        let expected = typeByte(of: .flagsChanged)
        do {
            let observed = try read(
                UInt8.self,
                at    : typeOffset,
                from  : record,
                length: Int(declared)
            )
            return FlagsChangedRecordCheck(
                eventTypeHeld   : typeHeld,
                declaredLength  : declared,
                observedTypeByte: observed,
                expectedTypeByte: expected,
                failure         : observed == expected ? nil : .recordOffsetMismatch(
                    offset: typeOffset,
                    wrote : "CGEventType.flagsChanged",
                    read  : "0x\(String(observed, radix: 16, uppercase: true))"
                )
            )
        } catch let failure as SystemFailure {
            return failed(failure, typeHeld: typeHeld)
        } catch {
            return failed(.eventRecordUnavailable, typeHeld: typeHeld)
        }
    }
}
