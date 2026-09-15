//
//  FenceRunLoopThread.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreFoundation
import Foundation

/// FenceRunLoopThread is the thread the HID tap is delivered on. Adding the
/// tap's run loop source to `CFRunLoopGetMain()` puts the callback in the same
/// queue as the consumer's UI: every window resize, every layout pass and every
/// modal run loop of the host application becomes latency the person's own
/// cursor has to wait for, and a tap that answers late is a tap WindowServer
/// disables.
///
/// So the fence runs its own thread with its own run loop at
/// `.userInteractive`, and nothing else is ever scheduled on it. The class is a
/// `Thread` subclass rather than a `Thread(block:)` because the block form
/// wants a `@Sendable` closure and the CoreFoundation values it would have to
/// capture are not `Sendable`; holding them as properties of an
/// `@unchecked Sendable` subclass says the same thing without lying about the
/// closure.
nonisolated final class FenceRunLoopThread: Thread, @unchecked Sendable {

    /// How long an acquisition waits for the thread to publish its run loop
    /// before refusing, and how long teardown waits for `CFRunLoopRun` to
    /// return. Starting a thread is microseconds; a second is the point at
    /// which something is wrong rather than slow. The shutdown wait is what
    /// keeps the mach port alive until the loop has stopped using it.
    static let handshakeTimeout: TimeInterval = 1

    private let source : CFRunLoopSource
    private let started = DispatchSemaphore(value: 0)
    private let ended   = DispatchSemaphore(value: 0)

    /// The run loop of this thread, published once `started` is signalled. The
    /// semaphore is the happens-before edge, so no lock is needed around it.
    private var loop: CFRunLoop?

    init(source: CFRunLoopSource) {
        self.source = source
        super.init()
        name             = "dev.forte.AgentSeatKit.fence"
        qualityOfService = .userInteractive
    }

    override func main() {
        let loop = CFRunLoopGetCurrent()
        self.loop = loop
        CFRunLoopAddSource(loop, source, .commonModes)
        started.signal()
        // Returns when `stopAndWait` calls CFRunLoopStop, or immediately if the
        // mach port was invalidated first, which is why teardown stops before
        // it invalidates.
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, source, .commonModes)
        ended.signal()
    }

    /// Starts the thread and returns only once the source is on its run loop.
    /// False means the run loop never came up, and the caller must refuse.
    func startAndWait() -> Bool {
        start()
        return started.wait(timeout: .now() + Self.handshakeTimeout) == .success
    }

    /// Stops the run loop and waits for the thread to leave it, so the caller
    /// can invalidate the mach port knowing nobody is still reading it. False
    /// means the thread did not answer inside the timeout.
    @discardableResult
    func stopAndWait() -> Bool {
        guard let loop else { return false }
        CFRunLoopStop(loop)
        return ended.wait(timeout: .now() + Self.handshakeTimeout) == .success
    }
}
