import Foundation
import Testing
@testable import mecum

@Suite("Peek refresh timing")
struct PeekRefreshScheduleTests {
    @Test func processingTimeDoesNotAddAnExtraIdleInterval() {
        let start = ContinuousClock.now
        var refresh = PeekRefreshSchedule(interval: .milliseconds(500), now: start)
        refresh.complete(refresh.ticket(at: start), at: start.advanced(by: .milliseconds(350)))
        #expect(refresh.nextObservation == start.advanced(by: .milliseconds(500)))
    }

    @Test func slowReadCanRefreshImmediatelyAfterCompletion() {
        let start = ContinuousClock.now
        var refresh = PeekRefreshSchedule(interval: .milliseconds(500), now: start)
        refresh.complete(refresh.ticket(at: start), at: start.advanced(by: .milliseconds(800)))
        #expect(refresh.nextObservation == start.advanced(by: .milliseconds(800)))
    }

    @Test func staleCompletionCannotDelayARefreshRequestedByInput() {
        let start = ContinuousClock.now
        var refresh = PeekRefreshSchedule(interval: .seconds(10), now: start)
        let old = refresh.ticket(at: start)
        refresh.invalidate(at: start.advanced(by: .milliseconds(200)))
        refresh.complete(old, at: start.advanced(by: .milliseconds(250)))
        #expect(!refresh.isCurrent(old))
        #expect(refresh.nextObservation == start.advanced(by: .milliseconds(300)))
        refresh.invalidate(at: start.advanced(by: .milliseconds(280)))
        #expect(refresh.nextObservation == start.advanced(by: .milliseconds(380)))
    }
}
