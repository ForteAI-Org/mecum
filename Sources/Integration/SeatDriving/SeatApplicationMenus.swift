import AccessibilityActions
import EngineCore
import Foundation
import SeatCore
import SeatSession
import SeatCapture
import WindowPlacement

/// SeatApplicationMenus binds native, application-level commands to the Seat's observed window.
/// It never raises or changes AX focus to manufacture that binding. Unavailable identity refuses.
@MainActor
public final class SeatApplicationMenus: ApplicationMenuOperating {
    private let target: SeatTarget
    private let native = AccessibilityMenuController()

    public init(target: SeatTarget) { self.target = target }

    public func catalog(processID: pid_t) throws -> MenuCatalog {
        guard try target.currentWindow().reference.processID == processID else {
            throw MenuFailure("The menu belongs to a different application than the Seat.")
        }
        return try native.catalog(processID: processID)
    }

    public func invoke(path: [String], processID: pid_t) async throws -> MenuDelivery {
        let seat = try target.agentSeat()
        let turn = try await seat.acquire()
        var deliveryReturned = false
        do {
            let observed = try await target.currentObservation()
            let result = try await seat.performNativeMenuAction(observation: observed.reference, turn: turn) {
                window, boundary in
                guard window.processID == processID else {
                    throw MenuFailure("The menu belongs to a different application than the observation.")
                }
                return try native.invoke(path: path, processID: processID) { focused in
                    guard WindowRelocator.windowNumber(of: focused) == window.windowNumber else {
                        throw MenuFailure("The application's focused window differs from the observed Seat window.")
                    }
                    try boundary()
                }
            }
            deliveryReturned = true
            target.spendObservation()
            try seat.release(turn)
            return result
        } catch {
            if deliveryReturned { return .uncertain("Menu was requested but Turn cleanup failed: \(error). Do not replay.") }
            target.spendObservation()
            do { try seat.release(turn) }
            catch let cleanup { throw MenuFailure("Menu operation failed: \(error); releasing its Turn failed: \(cleanup).") }
            throw error
        }
    }
}
