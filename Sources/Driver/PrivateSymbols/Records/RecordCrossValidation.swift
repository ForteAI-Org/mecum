//
//  RecordCrossValidation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

nonisolated extension RecordLayout {

    /// Runs the cross-validation of step 3 of the compatibility suite against
    /// the running system, on an event that is created and thrown away. Nothing
    /// is posted, no permission is touched, and the whole thing costs one event
    /// allocation and six loads: it is meant to run at every Facility start.
    ///
    /// The proof is bidirectional for the integer offsets, because one
    /// direction is not a round trip: writing through field 51 and finding the
    /// bytes at 0x3C shows where the setter lands, and writing 0x3C and reading
    /// it back through field 51 shows that the field still describes that byte.
    /// For the window-local point no public field reads the two `Double`s back,
    /// so the proof is the setter writing what the kit expects to find.
    public static func crossValidate(using table: SymbolTable = .shared) -> RecordLayoutCheck {
        func failed(_ failure: SystemFailure) -> RecordLayoutCheck {
            RecordLayoutCheck(
                declaredLength          : nil,
                windowNumberRoundTrip   : false,
                ownerConnectionRoundTrip: false,
                windowLocationRoundTrip : false,
                failure                 : failure
            )
        }

        guard
            let recordPointer = table.function(
                .eventRecordPointer,
                as: SymbolABI.EventRecordPointer.self
            ),
            let source = CGEventSource(stateID: .privateState),
            let event = CGEvent(
                mouseEventSource : source,
                mouseType        : .leftMouseDown,
                mouseCursorPosition: CGPoint(x: 100, y: 200),
                mouseButton      : .left
            )
        else {
            return failed(.eventRecordUnavailable)
        }

        let eventPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(event).toOpaque())
        guard let record = recordPointer(UnsafeRawPointer(eventPointer)) else {
            return failed(.eventRecordUnavailable)
        }

        let declared: UInt32
        do {
            declared = try validateDeclaredLength(of: record)
        } catch let failure as SystemFailure {
            return failed(failure)
        } catch {
            return failed(.eventRecordUnavailable)
        }

        let length = Int(declared)
        var failure: SystemFailure?

        func roundTripInteger(field id: UInt32, offset: Int, probe: UInt32) -> Bool {
            guard let field = CGEventField(rawValue: id) else { return false }
            do {
                event.setIntegerValueField(field, value: Int64(probe))
                let stored = try read(UInt32.self, at: offset, from: record, length: length)
                guard stored == probe else {
                    failure = failure ?? .recordOffsetMismatch(
                        offset: offset,
                        wrote : "field \(id) = \(probe)",
                        read  : "\(stored)"
                    )
                    return false
                }
                let mirrored = probe ^ 0x0101_0101
                try write(mirrored, at: offset, into: record, length: length)
                let readBack = UInt32(truncatingIfNeeded: event.getIntegerValueField(field))
                guard readBack == mirrored else {
                    failure = failure ?? .recordOffsetMismatch(
                        offset: offset,
                        wrote : "\(mirrored)",
                        read  : "field \(id) = \(readBack)"
                    )
                    return false
                }
                return true
            } catch let thrown as SystemFailure {
                failure = failure ?? thrown
                return false
            } catch {
                return false
            }
        }

        let windowNumber    = roundTripInteger(
            field : windowNumberField,
            offset: windowNumberOffset,
            probe : 0x7E7F_8081
        )
        let ownerConnection = roundTripInteger(
            field : ownerConnectionField,
            offset: ownerConnectionOffset,
            probe : 0x8E8F_9091
        )

        var windowLocation = false
        if let setWindowLocation = table.function(
            .setWindowLocation,
            as: SymbolABI.SetWindowLocation.self
        ) {
            let probeX = 11.5
            let probeY = 22.25
            setWindowLocation(eventPointer, probeX, probeY)
            do {
                let storedX = try read(Double.self, at: localPointXOffset, from: record, length: length)
                let storedY = try read(Double.self, at: localPointYOffset, from: record, length: length)
                windowLocation = storedX == probeX && storedY == probeY
                if !windowLocation {
                    failure = failure ?? .recordOffsetMismatch(
                        offset: localPointXOffset,
                        wrote : "CGEventSetWindowLocation(\(probeX), \(probeY))",
                        read  : "(\(storedX), \(storedY))"
                    )
                }
            } catch let thrown as SystemFailure {
                failure = failure ?? thrown
            } catch {
            }
        }

        return RecordLayoutCheck(
            declaredLength          : declared,
            windowNumberRoundTrip   : windowNumber,
            ownerConnectionRoundTrip: ownerConnection,
            windowLocationRoundTrip : windowLocation,
            failure                 : failure
        )
    }
}
