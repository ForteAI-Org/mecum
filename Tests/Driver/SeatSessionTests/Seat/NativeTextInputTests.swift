//
//  NativeTextInputTests.swift
//  AgentSeatKit
//

import Dispatch
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
private final class PreparedTextInputSender: FakeSender, NativeTextInputPreparing, @unchecked Sendable {
    var starts = 0
    var restores = 0
    var cleanup: InputCleanupResult = .succeeded

    func withNativeTextInput(
        to window    : WindowReference,
        correlationID: Int64,
        within       : Duration,
        operation    : @escaping @Sendable () async throws -> Void
    ) async throws -> InputCleanupResult {
        await MainActor.run { starts += 1 }
        do {
            try await operation()
            await MainActor.run { restores += 1 }
            return await MainActor.run { cleanup }
        } catch {
            await MainActor.run { restores += 1 }
            let result = await MainActor.run { cleanup }
            throw NativeTextInputFailure(
                cause  : error,
                cleanup: result
            )
        }
    }

    func cancelNativeTextInput(correlationID: Int64) async -> InputCleanupResult {
        .succeeded
    }
}

@MainActor
@Suite("Qualified native text input admission")
struct NativeTextInputTests {
    private static func refusesKey(
        _ reason: NativeTextInputRefusal,
        seat    : AgentSeat,
        turn    : Turn
    ) async throws {
        let observation = try await observedReference(seat)
        await #expect(throws: InputFailure.nativeTextInputRefused(reason)) {
            let receipt = try await seat.send(
                .key(
                    virtualKey: 2,
                    text      : ""
                ),
                observation: observation,
                turn       : turn
            )
            try seat.confirm(
                receipt,
                .observed
            )
        }
    }

    private func adopted(
        sensing : FakeSensing,
        sender  : PreparedTextInputSender,
        platform: any InputPlatform = QtPlatform(),
        evidence: InputEndpointEvidence = .attestedSurfaceItself
    ) async throws -> (AgentSeat, AdoptedWindow) {
        sensing.geometry = FakeGeometry.reference(frame: FakeGeometry.adoptedWindow.frame)
        var endpoints = EndpointDiscovery(
            pointer: { _, _, _, _ in .failure(.noNodeAtPoint) },
            keyboardContext: { _, chain, generation in
                let now = DispatchTime.now().uptimeNanoseconds
                guard let window = sensing.windowGeometry(of: chain.surface.windowNumber),
                      let geometry = sensing.windowGeometryObservation(of: window),
                      let endpoint = ResolvedInputEndpoint(
                        kind                   : .keyboardContext,
                        geometry               : geometry,
                        evidence               : evidence,
                        relation               : .logicalSurface,
                        logicalSurface         : chain.surface,
                        accessibilityProcessID : chain.surface.processID,
                        selectionGeneration    : generation,
                        resolvedAtNanoseconds  : now,
                        expiresAtNanoseconds   : now + 500_000_000,
                        focusedNodeWindowNumber: chain.surface.windowNumber
                      ) else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
                return .success(endpoint)
            },
            identity: { sensing.windowGeometry(of: $0)?.identity },
            focusedWindowNumber: { _ in FakeGeometry.windowNumber }
        )
        let keyboardContext = endpoints.keyboardContext
        endpoints.windowlessContent = { processID, _, chain, generation in
            keyboardContext(processID, chain, generation)
        }
        let seat = makeSeat(
            sensing  : sensing,
            sender   : sender,
            endpoints: endpoints
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: platform
        )
        return (seat, window)
    }

    @Test(
        "native composition preserves fresh observations, confirmation and Turn ownership",
        arguments: ["Qt", "Chromium"]
    )
    func freshDecisions(family: String) async throws {
        let sender = PreparedTextInputSender()
        let platform: any InputPlatform = family == "Qt"
            ? QtPlatform() : ChromiumPlatform(nativeTextInputIsQualified: true)
        let (seat, _) = try await adopted(
            sensing : FakeSensing(),
            sender  : sender,
            platform: platform,
            evidence: family == "Qt" ? .attestedSurfaceItself : .windowlessContentOfSurface
        )
        let turn = try await seat.acquire()
        let entry = try await observedReference(seat)
        let cleanup = try await seat.withNativeTextInput(
            observation: entry,
            turn       : turn
        ) {
            await #expect(throws: ObservationAdmissionRefusal.self) {
                try await seat.send(
                    .key(
                        virtualKey: 2,
                        text      : ""
                    ),
                    observation: entry,
                    turn       : turn
                )
            }
            #expect(throws: InputFailure.nativeTextInputRefused(.contextActive)) { try seat.release(turn) }
            let fresh = try await observedReference(seat)
            for forbidden: InputCommand in [
                .text("é"),
                .insertText("é"),
                .key(
                    virtualKey: 2,
                    text      : "é"
                ),
                .key(
                    virtualKey: 2,
                    text      : "",
                    phase     : .down
                ),
                .key(
                    virtualKey: 2,
                    text      : "",
                    modifiers : .command
                ),
            ] {
                await #expect(throws: InputFailure.nativeTextInputRefused(.commandUnsupported)) {
                    try await seat.send(
                        forbidden,
                        observation: fresh,
                        turn       : turn
                    )
                }
            }
            let first = try await seat.send(
                .key(
                    virtualKey: 2,
                    text      : "",
                    modifiers : .option
                ),
                observation: fresh,
                turn       : turn
            )
            try seat.confirm(
                first,
                .observed
            )
            await #expect(throws: ObservationAdmissionRefusal.self) {
                try await seat.send(
                    .key(
                        virtualKey: 2,
                        text      : ""
                    ),
                    observation: fresh,
                    turn       : turn
                )
            }
            let second = try await seat.send(
                .key(
                    virtualKey: 2,
                    text      : ""
                ),
                observation: try await observedReference(seat),
                turn       : turn
            )
            try seat.confirm(
                second,
                .observed
            )
        }
        #expect(cleanup == .succeeded)
        #expect(sender.sent.count == 2)
        #expect(sender.starts == 1 && sender.restores == 1)
        try seat.release(turn)
    }

    @Test("native composition refuses a newly observed different recipient")
    func changedRecipient() async throws {
        let sender = PreparedTextInputSender()
        let sensing = FakeSensing()
        let (seat, _) = try await adopted(
            sensing: sensing,
            sender : sender
        )
        let reference = FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame,
            windowNumber: 778
        )
        sensing.additionalWindows[778] = reference
        let second = try await seat.adopt(
            reference,
            platform: QtPlatform()
        )
        let first = try #require(seat.adoptedWindows.first { $0.id != second.id })
        _ = try await seat.switchTarget(to: first)
        let turn = try await seat.acquire()
        _ = try await seat.withNativeTextInput(
            observation: try await observedReference(seat),
            turn       : turn
        ) {
            _ = try await seat.switchTarget(to: second)
            await #expect(throws: InputFailure.nativeTextInputRefused(.contextMismatch)) {
                try await seat.send(
                    .key(
                        virtualKey: 2,
                        text      : ""
                    ),
                    observation: try await observedReference(seat),
                    turn       : turn
                )
            }
        }
        #expect(sender.sent.isEmpty)
        #expect(sender.restores == 1)
        try seat.release(turn)
    }

    @Test("detached work and an escaped child cannot post through a composition scope")
    func taskOwnership() async throws {
        let sender = PreparedTextInputSender()
        let (seat, _) = try await adopted(
            sensing: FakeSensing(),
            sender : sender
        )
        let turn = try await seat.acquire()
        var allowsLateCommand = false
        var escaped: Task<Void, any Error>?
        _ = try await seat.withNativeTextInput(
            observation: try await observedReference(seat),
            turn       : turn
        ) {
            let outside = Task.detached {
                try await Self.refusesKey(
                    .contextMismatch,
                    seat: seat,
                    turn: turn
                )
            }
            try await outside.value
            escaped = Task { @MainActor in
                while !allowsLateCommand { await Task.yield() }
                try await Self.refusesKey(
                    .contextClosed,
                    seat: seat,
                    turn: turn
                )
            }
        }
        allowsLateCommand = true
        let child = try #require(escaped)
        try await child.value
        #expect(sender.sent.isEmpty)
        #expect(sender.starts == 1 && sender.restores == 1)
        try seat.release(turn)
    }

    @Test("a consumer failure ends preparation before the Turn is released")
    func consumerFailure() async throws {
        enum Failure: Error { case stopped }
        let sender = PreparedTextInputSender()
        let (seat, _) = try await adopted(
            sensing: FakeSensing(),
            sender : sender
        )
        let turn = try await seat.acquire()
        do {
            _ = try await seat.withNativeTextInput(
                observation: try await observedReference(seat),
                turn       : turn
            ) { throw Failure.stopped }
            Issue.record("The failed body unexpectedly returned")
        } catch let failure as NativeTextInputFailure {
            #expect(failure.cause as? Failure == .stopped)
            #expect(failure.cleanup == .succeeded)
        }
        #expect(sender.sent.isEmpty && sender.restores == 1)
        try seat.release(turn)
    }

    @Test("failed context restoration degrades without inventing delivery")
    func cleanupFailure() async throws {
        let sender = PreparedTextInputSender()
        sender.cleanup = .failed(code: -17)
        let (seat, _) = try await adopted(
            sensing: FakeSensing(),
            sender : sender
        )
        let turn = try await seat.acquire()
        let cleanup = try await seat.withNativeTextInput(
            observation: try await observedReference(seat),
            turn       : turn
        ) {}
        #expect(cleanup == .failed(code: -17))
        #expect(seat.state == .degraded)
        #expect(seat.unconfirmedCommandCount == 0)
        #expect(sender.sent.isEmpty && sender.restores == 1)
        try seat.release(turn)
    }

    @Test(
        "a composition scope does not grant the recipe to an unqualified family",
        arguments: ["AppKit", "Unqualified Chromium shell"]
    )
    func otherFamily(family: String) async throws {
        let sender = PreparedTextInputSender()
        let platform: any InputPlatform = family == "AppKit" ? AppKitPlatform() : ChromiumPlatform()
        let (seat, _) = try await adopted(
            sensing : FakeSensing(),
            sender  : sender,
            platform: platform
        )
        let turn = try await seat.acquire()
        await #expect(throws: InputFailure.nativeTextInputRefused(.unsupported)) {
            try await seat.withNativeTextInput(
                observation: try await observedReference(seat),
                turn       : turn
            ) { Issue.record("The unsupported body was entered") }
        }
        #expect(sender.sent.isEmpty && sender.starts == 0)
        try seat.release(turn)
    }
}
