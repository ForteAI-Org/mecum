import Dispatch
import PrivateSymbols
import SeatCore

/// The private actuation half of recovery. Package-only: the session binds
/// its destination to a previously observed user window on a physical display.
/// This restores focus without pointer input and requests no all-window raise.
package final class UserFocusRestorer {
    package let readiness: FacilityReadiness
    package private(set) var timing = UserFocusRequestTiming()
    private let usesKeyRecords: Bool
    private let preparation: AppKitStatePreparation
    private let setFrontProcess: SymbolABI.SetFrontProcess
    private let getFrontProcess: SymbolABI.GetFrontProcess
    private var preparedDestination: AppKitStatePreparation.Participant?
    private var preparedTargets: [Int32: AppKitStatePreparation.Participant.SerialNumber] = [:]

    package init(allowUnvalidatedBuild: Bool, usesKeyRecords: Bool = false, table: SymbolTable = .shared) throws {
        let gate = FacilityGate.current(facility: .focusRecovery,
                                       allowUnvalidatedBuild: allowUnvalidatedBuild, table: table)
        guard gate.mayAct else { throw InputFailure.facilityUnavailable(gate.readiness) }
        guard let connection = table.function(.mainConnectionID, as: SymbolABI.MainConnectionID.self),
              let restore = table.function(.setFrontProcess, as: SymbolABI.SetFrontProcess.self),
              let front = table.function(.getFrontProcess, as: SymbolABI.GetFrontProcess.self),
              let preparation = AppKitStatePreparation(table: table, connectionID: connection())
        else { throw InputFailure.primitiveUnavailable(PrivateSymbol.setFrontProcess.rawValue) }
        self.usesKeyRecords = usesKeyRecords
        self.readiness = gate.readiness
        self.preparation = preparation
        self.setFrontProcess = restore
        self.getFrontProcess = front
    }

    /// Read-only identity resolution shares the session's preparation lifetime.
    /// The retained PSN binds a request to the observed user process even if a
    /// Window ID disappears or is reused; no newly discovered owner is activated.
    package func prepare(_ window: WindowReference, targets: [WindowReference]) throws {
        preparedDestination = nil
        preparedTargets = [:]
        let destination = try preparation.participant(for: window)
        var serialNumbers: [Int32: AppKitStatePreparation.Participant.SerialNumber] = [:]
        for target in targets where serialNumbers[target.processID] == nil {
            serialNumbers[target.processID] = try preparation.participant(for: target).serialNumber
        }
        preparedDestination = destination
        preparedTargets = serialNumbers
    }

    package func isFrontmost(processID: Int32) -> Bool {
        guard let expected = preparedTargets[processID] else { return false }
        var current = AppKitStatePreparation.Participant.SerialNumber()
        let code = withUnsafeMutablePointer(to: &current) {
            getFrontProcess(UnsafeMutableRawPointer($0))
        }
        return code == 0 && current == expected
    }

    /// Requests the prepared destination and reports the whole call's duration.
    ///
    /// The full-call timer opens on the first line, before the timing reset and
    /// the destination guard, and closes in a `defer`, so every return path,
    /// including a throw, records `restoreCallNanoseconds`. The measured window
    /// contains three clock reads: its own two and the control read whose cost
    /// is reported in `restoreCallControlNanoseconds` and never subtracted.
    /// Errors and effects of the request itself are unchanged by this timing.
    package func restore(_ window: WindowReference) throws -> Int32 {
        let entry = DispatchTime.now().uptimeNanoseconds
        let control = DispatchTime.now().uptimeNanoseconds
        timing = UserFocusRequestTiming()
        timing.restoreCallControlNanoseconds = control &- entry
        defer { timing.restoreCallNanoseconds = DispatchTime.now().uptimeNanoseconds &- entry }
        guard var participant = preparedDestination,
              participant.processID == window.processID,
              Int(participant.windowNumber) == window.windowNumber
        else { throw InputFailure.inputPaused([.destinationNotPrepared]) }
        preparedDestination = nil
        let start = DispatchTime.now().uptimeNanoseconds
        let windowNumber = participant.windowNumber
        let code = withUnsafeMutablePointer(to: &participant.serialNumber) {
            setFrontProcess(UnsafeMutableRawPointer($0), windowNumber, 0x200)
        }
        timing.activationNanoseconds = DispatchTime.now().uptimeNanoseconds &- start
        // Only the package's A/B campaign opts into the destination-bound pair.
        if code == 0, usesKeyRecords {
            var checkpoint = DispatchTime.now().uptimeNanoseconds
            try preparation.makeKey(participant) { step in
                let current = DispatchTime.now().uptimeNanoseconds
                if step == .keyWindowFirst { self.timing.firstKeyNanoseconds = current &- checkpoint }
                else { self.timing.secondKeyNanoseconds = current &- checkpoint }
                checkpoint = current
            }
        }
        return code
    }
}
