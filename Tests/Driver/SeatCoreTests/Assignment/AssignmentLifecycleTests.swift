//
//  AssignmentLifecycleTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

@testable import SeatCore
import Testing

/// Who is entrusted to the agent and until when, with no window, no display and
/// no process attached.
@Suite("The assignment lifecycle")
struct AssignmentLifecycleTests {

    typealias Fixture = AssignmentFixtures

    // MARK: Taking an instance

    @Test("An attested instance is accepted, with its generation and its start")
    func acceptsAttestedInstance() {
        var lifecycle = AssignmentLifecycle()
        let outcome   = lifecycle.accept(
            instance   : Fixture.target,
            attestation: .windowServerAttested,
            at         : 1_000
        )

        #expect(outcome == .success(AssignedApplication(
            instance                    : Fixture.target,
            generation                  : 1,
            handoverStartedAtNanoseconds: 1_000
        )))
        #expect(lifecycle.isAssigned)
        #expect(lifecycle.authorises(Fixture.target))
    }

    @Test(
        "An identity that is only a PID, or unverified, is refused before any effect",
        arguments: [InstanceAttestation.processIdentifierOnly, .unverified]
    )
    func refusesUnattestedIdentity(_ attestation: InstanceAttestation) {
        var lifecycle = AssignmentLifecycle()
        let outcome   = lifecycle.accept(instance: Fixture.target, attestation: attestation, at: 0)

        #expect(outcome == .failure(.identityNotAttested))
        #expect(!lifecycle.isAssigned)
        #expect(lifecycle.generation == 0)
    }

    @Test("A second instance is refused while one is assigned")
    func refusesSecondInstance() {
        var lifecycle = AssignmentLifecycle()
        _ = lifecycle.accept(instance: Fixture.target, attestation: .windowServerAttested, at: 0)
        let second = lifecycle.accept(instance: Fixture.helper, attestation: .windowServerAttested, at: 1)

        #expect(second == .failure(.anotherInstanceAssigned))
        #expect(lifecycle.current?.instance == Fixture.target)
    }

    // MARK: A reused PID inherits nothing

    @Test("The same PID after a restart is not the assigned instance")
    func reusedProcessIdentifierIsNotAuthorised() {
        var lifecycle = AssignmentLifecycle()
        _ = lifecycle.accept(instance: Fixture.target, attestation: .windowServerAttested, at: 0)

        #expect(Fixture.restart.processID == Fixture.target.processID)
        #expect(!lifecycle.authorises(Fixture.restart))
        #expect(lifecycle.noteExit(of: Fixture.restart) == nil)
        #expect(lifecycle.isAssigned)
    }

    @Test("A restarted application needs a new handover, with a new generation")
    func restartNeedsANewHandover() {
        var lifecycle = AssignmentLifecycle()
        _ = lifecycle.accept(instance: Fixture.target, attestation: .windowServerAttested, at: 0)
        _ = lifecycle.noteExit(of: Fixture.target)

        let again = lifecycle.accept(instance: Fixture.restart, attestation: .windowServerAttested, at: 5)
        #expect((try? again.get())?.generation == 2)
        #expect(lifecycle.authorises(Fixture.restart))
    }

    // MARK: What ends it, and what does not

    @Test("An explicit release ends it and records why")
    func explicitReleaseEndsIt() {
        var lifecycle = AssignmentLifecycle()
        _ = lifecycle.accept(instance: Fixture.target, attestation: .windowServerAttested, at: 0)

        #expect(lifecycle.release()?.instance == Fixture.target)
        #expect(lifecycle.lastEnd == .explicitRelease)
        #expect(!lifecycle.isAssigned)
    }

    @Test("The exit of the assigned instance ends it")
    func exitEndsIt() {
        var lifecycle = AssignmentLifecycle()
        _ = lifecycle.accept(instance: Fixture.target, attestation: .windowServerAttested, at: 0)

        #expect(lifecycle.noteExit(of: Fixture.target)?.instance == Fixture.target)
        #expect(lifecycle.lastEnd == .instanceExited)
    }

    @Test("Stopping the seat ends it and refuses every later handover")
    func seatStopEndsItTerminally() {
        var lifecycle = AssignmentLifecycle()
        _ = lifecycle.accept(instance: Fixture.target, attestation: .windowServerAttested, at: 0)

        #expect(lifecycle.stopSeat()?.instance == Fixture.target)
        #expect(lifecycle.lastEnd == .seatStopped)
        #expect(lifecycle.isSeatStopped)
        #expect(
            lifecycle.accept(instance: Fixture.target, attestation: .windowServerAttested, at: 9)
                == .failure(.seatStopped)
        )
    }

    @Test("Releasing nothing answers nothing, so a double release is visible")
    func releasingNothingIsVisible() {
        var lifecycle = AssignmentLifecycle()
        _ = lifecycle.accept(instance: Fixture.target, attestation: .windowServerAttested, at: 0)
        _ = lifecycle.release()

        #expect(lifecycle.release() == nil)
    }
}
