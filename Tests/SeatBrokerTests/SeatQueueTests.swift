//
//  SeatQueueTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Testing
@testable import SeatBroker

/// The queue's whole point is that the wait is real, so these drive it with two
/// callers at once rather than asserting on its bookkeeping. A session costs one
/// allocation and raises no display until something is adopted, which is what
/// lets a unit test hold seats at all.
@MainActor private func makeQueue(capacity: Int = 1) -> SeatQueue {
    SeatBroker(configuration: .init(seatCapacity: capacity)).queue
}

/// Long enough for a task that is about to suspend on the queue to get there,
/// short enough that a suite of these stays quick.
private func letTheOtherTaskReachItsWait() async {
    try? await Task.sleep(for: .milliseconds(60))
}

@Test @MainActor func theSecondCallerDoesNotGetASeatUntilTheFirstGivesItBack() async throws {
    let queue = makeQueue()
    let first = try await queue.acquire("first")

    var secondWasGranted = false
    let second = Task { @MainActor in
        let lease = try await queue.acquire("second")
        secondWasGranted = true
        return lease
    }
    await letTheOtherTaskReachItsWait()

    // The load bearing assertion: a seat that is taken is not handed out again,
    // and the caller is parked rather than refused.
    #expect(secondWasGranted == false)
    #expect(queue.entries.count == 2)
    #expect(queue.entries.first?.state == .acting)
    #expect(queue.entries.last?.state == .waiting)

    first.giveBack()
    let lease = try await second.value
    #expect(secondWasGranted == true)
    #expect(queue.entries.map(\.state) == [.acting])
    lease.giveBack()
    #expect(queue.entries.isEmpty)
}

@Test @MainActor func seatsAreHandedOutInTheOrderTheyWereAskedFor() async throws {
    let queue = makeQueue()
    let held = try await queue.acquire("holder")

    var granted: [String] = []
    var tasks: [Task<Void, any Error>] = []
    for name in ["a", "b", "c"] {
        tasks.append(Task { @MainActor in
            let lease = try await queue.acquire(name)
            granted.append(name)
            lease.giveBack()
        })
        // Staggered so the arrival order is the one under test rather than
        // whatever order three tasks happen to start in.
        await letTheOtherTaskReachItsWait()
    }

    #expect(queue.entries.map(\.label) == ["holder", "a", "b", "c"])
    held.giveBack()
    for task in tasks { _ = try await task.value }

    #expect(granted == ["a", "b", "c"])
    #expect(queue.entries.isEmpty)
}

@Test @MainActor func aSeatGivenBackIsKeptWarmAndHandedToTheNextEntry() async throws {
    let queue = makeQueue()
    let first = try await queue.acquire("first")
    let firstSession = ObjectIdentifier(first.session)
    first.giveBack()

    let second = try await queue.acquire("second")
    // Creating the display behind a seat costs about 380 ms and holding an idle
    // one costs nothing measurable, so the queue parks seats instead of remaking
    // them. A fresh session here would be that measurement ignored.
    #expect(ObjectIdentifier(second.session) == firstSession)
    second.giveBack()
}

@Test @MainActor func cancellingAWaitingEntryTakesItOutOfTheQueue() async throws {
    let queue = makeQueue()
    let held = try await queue.acquire("holder")

    let waiting = Task { @MainActor in try await queue.acquire("waiting") }
    await letTheOtherTaskReachItsWait()
    #expect(queue.entries.count == 2)

    guard let id = queue.entries.last?.id else { Issue.record("no waiting entry"); return }
    queue.cancel(id)

    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(queue.entries.map(\.label) == ["holder"])

    // And the seat is still the holder's: a cancellation is one entry leaving,
    // never a seat changing hands.
    #expect(queue.entries.first?.state == .acting)
    held.giveBack()
}

@Test @MainActor func cancellingTheCallingTaskWhileItWaitsLeavesTheQueue() async throws {
    let queue = makeQueue()
    let held = try await queue.acquire("holder")

    let waiting = Task { @MainActor in try await queue.acquire("waiting") }
    await letTheOtherTaskReachItsWait()
    #expect(queue.entries.count == 2)

    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    await letTheOtherTaskReachItsWait()
    #expect(queue.entries.map(\.label) == ["holder"])
    held.giveBack()
}

@Test @MainActor func capacityLetsThatManyActAtOnceAndNoMore() async throws {
    // The number the kit cannot honour yet, driven here to prove this type is
    // not what holds it at one.
    let queue = makeQueue(capacity: 2)
    let first = try await queue.acquire("first")
    let second = try await queue.acquire("second")
    #expect(queue.entries.map(\.state) == [.acting, .acting])

    var thirdWasGranted = false
    let third = Task { @MainActor in
        let lease = try await queue.acquire("third")
        thirdWasGranted = true
        return lease
    }
    await letTheOtherTaskReachItsWait()
    #expect(thirdWasGranted == false)

    first.giveBack()
    let lease = try await third.value
    #expect(thirdWasGranted == true)
    lease.giveBack()
    second.giveBack()
    #expect(queue.entries.isEmpty)
}

@Test @MainActor func runGivesTheSeatBackHoweverTheBodyEnds() async throws {
    struct Boom: Error {}
    let queue = makeQueue()

    let value = try await queue.run("fine") { _ in 7 }
    #expect(value == 7)
    #expect(queue.entries.isEmpty)

    await #expect(throws: Boom.self) {
        try await queue.run("throws") { _ in throw Boom() }
    }
    // The seat has to be free after a body that threw, or one failure closes the
    // queue for everybody.
    #expect(queue.entries.isEmpty)
    let after = try await queue.acquire("after")
    after.giveBack()
}
