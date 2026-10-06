//
//  InputTargetExclusionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Synchronization
import Testing

@testable import SeatInput

@Suite("Target process exclusion")
struct InputTargetExclusionTests {

    @Test("an uncontended transaction reports no queue wait and leaves no PID entry")
    func uncontended() async throws {
        let exclusion = InputTargetExclusion()

        let lease = try await exclusion.acquire(processID: 101)

        #expect(lease.waitingNanoseconds == 0)
        #expect(exclusion.targetCount == 1)

        exclusion.release(lease)
        #expect(exclusion.targetCount == 0)
    }

    @Test("one PID is FIFO while a different PID remains independent")
    func fifoByProcess() async throws {
        let exclusion = InputTargetExclusion()
        let order = Mutex<[Int]>([])
        let first = try await exclusion.acquire(processID: 101)

        let second = Task {
            let lease = try await exclusion.acquire(processID: 101)
            defer { exclusion.release(lease) }
            order.withLock { $0.append(2) }
            try await Task.sleep(for: .milliseconds(10))
            return lease.waitingNanoseconds
        }
        await waitForWaiter(in: exclusion, processID: 101)

        let third = Task {
            let lease = try await exclusion.acquire(processID: 101)
            defer { exclusion.release(lease) }
            order.withLock { $0.append(3) }
            return lease.waitingNanoseconds
        }
        await waitForWaiterCount(2, in: exclusion, processID: 101)

        let independent = try await exclusion.acquire(processID: 202)
        #expect(independent.waitingNanoseconds == 0)
        exclusion.release(independent)

        exclusion.release(first)
        let secondWait = try await second.value
        let thirdWait  = try await third.value
        #expect(secondWait > 0)
        #expect(thirdWait > 0)
        #expect(order.withLock { $0 } == [2, 3])
        #expect(exclusion.targetCount == 0)
    }

    @Test("a cancelled waiter leaves the queue and no registry residue")
    func cancelledWaiter() async throws {
        let exclusion = InputTargetExclusion()
        let held = try await exclusion.acquire(processID: 101)
        let cancelled = Task { try await exclusion.acquire(processID: 101) }

        await waitForWaiter(in: exclusion, processID: 101)
        cancelled.cancel()

        do {
            let lease = try await cancelled.value
            exclusion.release(lease)
            Issue.record("cancelled waiter acquired the exclusion")
        } catch let cancellation as InputTargetExclusion.Cancellation {
            #expect(cancellation.wait?.nanoseconds ?? 0 > 0)
        } catch {
            Issue.record("cancelled waiter threw \(type(of: error))")
        }
        #expect(exclusion.waitingCount(processID: 101) == 0)

        exclusion.release(held)
        #expect(exclusion.targetCount == 0)
    }

    @Test("cancelling the head waiter preserves the live waiter behind it")
    func cancelledHead() async throws {
        let exclusion = InputTargetExclusion()
        let held = try await exclusion.acquire(processID: 101)
        let cancelled = Task { try await exclusion.acquire(processID: 101) }
        await waitForWaiter(in: exclusion, processID: 101)

        let survivor = Task { try await exclusion.acquire(processID: 101) }
        await waitForWaiterCount(2, in: exclusion, processID: 101)
        cancelled.cancel()

        do {
            let lease = try await cancelled.value
            exclusion.release(lease)
            Issue.record("cancelled head waiter acquired the exclusion")
        } catch is InputTargetExclusion.Cancellation {
            #expect(exclusion.waitingCount(processID: 101) == 1)
        } catch {
            Issue.record("cancelled head waiter threw \(type(of: error))")
        }

        exclusion.release(held)
        let survivorLease = try await survivor.value
        #expect(survivorLease.waitingNanoseconds > 0)
        exclusion.release(survivorLease)
        #expect(exclusion.targetCount == 0)
    }

    @Test(
        "nonpositive PIDs are refused before entering the registry",
        arguments: [Int32(0), Int32(-1)]
    )
    func invalidProcessID(processID: Int32) async {
        let exclusion = InputTargetExclusion()

        await #expect(throws: InputFailure.self) {
            _ = try await exclusion.acquire(processID: processID)
        }
        #expect(exclusion.targetCount == 0)
    }

    private func waitForWaiter(
        in exclusion: InputTargetExclusion,
        processID  : Int32
    ) async {
        await waitForWaiterCount(1, in: exclusion, processID: processID)
    }

    private func waitForWaiterCount(
        _ expected : Int,
        in exclusion: InputTargetExclusion,
        processID  : Int32
    ) async {
        // Yield counts do not bound scheduling time: under load they can expire
        // before the child task gets a turn. Wait for the queue state instead.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if exclusion.waitingCount(processID: processID) == expected { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("waiter did not enter the exclusion queue")
    }
}
