import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
@Suite("Native menu observation boundary")
struct NativeMenuActionTests {
    @Test func consumesObservationWithoutFabricatingMouseInput() async throws {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let seat = makeSeat(sensing: sensing, sender: sender)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let turn = try await seat.acquire()
        let reference = try await observedReference(seat)
        var presses = 0
        let answer = try await seat.performNativeMenuAction(observation: reference, turn: turn) { target, boundary in
            #expect(target.windowNumber == window.id)
            try boundary()
            presses += 1
            return "requested"
        }
        #expect(answer == "requested")
        #expect(sender.sent.isEmpty)
        await #expect(throws: (any Error).self) {
            try await seat.performNativeMenuAction(observation: reference, turn: turn) { _, boundary in
                try boundary(); presses += 1
            }
        }
        #expect(presses == 1)
        #expect(seat.state == .ready)
        try seat.release(turn)
    }
    @Test func panicAndStaleObservationRefuseBeforeTheNativeBoundary() async throws {
        let sender = FakeSender()
        let seat = makeSeat(sender: sender)
        _ = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let turn = try await seat.acquire()
        let stale = try await observedReference(seat)
        _ = try await observedReference(seat)
        await #expect(throws: (any Error).self) {
            try await seat.performNativeMenuAction(observation: stale, turn: turn) { _, _ in
                Issue.record("stale callback must not run")
            }
        }
        let current = try await observedReference(seat)
        seat.stopAdmittingCommands()
        await #expect(throws: (any Error).self) {
            try await seat.performNativeMenuAction(observation: current, turn: turn) { _, boundary in
                try boundary(); Issue.record("panic must prevent AXPress")
            }
        }
        try seat.release(turn)
    }
}
