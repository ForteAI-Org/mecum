import AppKit
import CoreGraphics
import Foundation
import Synchronization

/// PassiveInteractionListener owns a listen-only tap on a dedicated run-loop thread.
/// It never posts or suppresses input. A bounded stream fails explicitly on overflow or tap loss.
/// Call stop() and await it before releasing the owner; cancellation uses the same joined teardown.
/// Event callbacks and the scroll/hover timer are confined to the tap thread. The gate alone crosses
/// threads and protects revision, stop state and the run loop. No perception runs inside a callback.
@MainActor
public final class PassiveInteractionListener {
    public let events: AsyncThrowingStream<InteractionEvent, any Error>
    private let context: TapContext
    private var activation: (any NSObjectProtocol)?
    private var isStopped = false

    public init(hover: Bool = true) throws {
        guard CGPreflightListenEventAccess() else { throw ListenerFailure.inputMonitoringDenied }
        let pair = AsyncThrowingStream<InteractionEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = pair.stream
        context = TapContext(continuation: pair.continuation, hover: hover, excludedPID: getpid())
        let owner = context
        pair.continuation.onTermination = { _ in owner.requestStop() }
        Thread { owner.run() }.start()
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            owner.focus(processID: app.processIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication { owner.focus(processID: app.processIdentifier) }
    }

    isolated deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        context.requestStop()
    }

    /// Advances on all captured input, including events outside a consumer's app filter.
    public var revision: UInt64 { context.revision }

    /// Returns the latest OS-routed pointer surface, once pointer input has been observed.
    /// A moved pointer or a vanished recipient stays unresolved until fresh routing arrives.
    public func windowUnderPointer() -> InteractionWindow? { context.windowUnderPointer() }

    /// Stops callbacks, flushes a pending scroll, finishes the stream and joins the tap thread.
    public func stop() async {
        if !isStopped {
            isStopped = true
            if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
            activation = nil
            context.requestStop()
        }
        await context.waitUntilFinished()
    }
}

/// TapContext confines mutable gesture state to its thread. Gate fields are mutex protected;
/// the continuation is thread safe. This is the only unchecked crossing of the C callback context.
private final class TapContext: @unchecked Sendable {
    // CFRunLoop scheduling/stop/wakeup are thread safe; gesture state never enters this shared gate.
    private struct Gate: @unchecked Sendable {
        var loop: CFRunLoop?
        var stopped = false
        var finished = false
        var revision: UInt64 = 0
        var pointerRoute: PointerRoute?
        var pendingFocus: Int32?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let gate = Mutex(Gate())
    private let continuation: AsyncThrowingStream<InteractionEvent, any Error>.Continuation
    private let hoverEnabled: Bool
    private let excludedPID: Int32
    private var scroll = ScrollGesture()
    private var dwell = HoverDwell()
    private var focusedProcessID: Int32?

    init(continuation: AsyncThrowingStream<InteractionEvent, any Error>.Continuation, hover: Bool, excludedPID: Int32) {
        self.continuation = continuation
        hoverEnabled = hover
        self.excludedPID = excludedPID
    }

    var revision: UInt64 { gate.withLock { $0.revision } }
    func windowUnderPointer() -> InteractionWindow? {
        guard let point = CGEvent(source: nil)?.location,
              let route = gate.withLock({ $0.pointerRoute }) else { return nil }
        return route.window(at: point, in: InteractionWindowReader.windows(excluding: excludedPID))
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let finished = gate.withLock { state in
                if state.finished { return true }
                state.waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }

    func requestStop() {
        gate.withLock {
            $0.stopped = true
            if let loop = $0.loop {
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
                CFRunLoopWakeUp(loop)
            }
        }
    }

    func focus(processID: Int32) {
        let loop = gate.withLock { state in
            if state.loop == nil { state.pendingFocus = processID }
            return state.loop
        }
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            guard focusedProcessID != processID else { return }
            focusedProcessID = processID
            if let pending = scroll.take() { emit(pending) }
            let now = ProcessInfo.processInfo.systemUptime
            dwell.reset(at: now)
            let revisions = advance()
            emit(InteractionEvent(
                kind: .focus, timestamp: Date(), startedAt: now, endedAt: now,
                precedingRevision: revisions.0, revision: revisions.1, point: .zero,
                window: nil, processID: processID
            ))
        }
        CFRunLoopWakeUp(loop)
    }

    func run() {
        defer {
            if let pending = scroll.take() { emit(pending) }
            continuation.finish()
            let waiters = gate.withLock { state in
                state.loop = nil
                state.finished = true
                let waiters = state.waiters
                state.waiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let mask = [CGEventType.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown,
                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: Self.callback, userInfo: pointer
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            continuation.finish(throwing: ListenerFailure.tapUnavailable)
            return
        }
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0) { [self] _ in
            tick()
        }
        CFRunLoopAddTimer(loop, timer, .commonModes)
        defer {
            CFRunLoopTimerInvalidate(timer)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        let start = gate.withLock { state in
            guard !state.stopped else { return false }
            state.loop = loop
            return true
        }
        if start {
            if let initial = gate.withLock({ $0.pendingFocus }) { focus(processID: initial) }
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            if !gate.withLock({ $0.stopped }) { continuation.finish(throwing: ListenerFailure.tapDisabled) }
        }
    }

    private func advance() -> (UInt64, UInt64) {
        gate.withLock { state in
            let before = state.revision
            state.revision &+= 1
            return (before, state.revision)
        }
    }

    private func emit(_ event: InteractionEvent) {
        if case .dropped = continuation.yield(event) {
            continuation.finish(throwing: ListenerFailure.bufferOverflow)
            requestStop()
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let pending = scroll.settled(at: now) { emit(pending) }
        guard hoverEnabled, let point = CGEvent(source: nil)?.location else { return }
        let window = windowUnderPointer()
        guard dwell.sample(point: point, window: window, at: now), let window else { return }
        emit(InteractionEvent(
            kind: .hover, timestamp: Date(), startedAt: now, endedAt: now,
            precedingRevision: revision, revision: revision, point: point,
            window: window, processID: window.processID
        ))
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            continuation.finish(throwing: ListenerFailure.tapDisabled)
            requestStop()
            return
        }
        // Events posted by this process are never described as manual user input.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(excludedPID) else { return }
        let route = PointerRoute(
            point: event.location,
            recipientWindowNumber: Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)),
            targetProcessID: Int32(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
        )
        if type != .keyDown { gate.withLock { $0.pointerRoute = route } }
        // Pointer movement warms ambient routing without invalidating a pre-click scene.
        if type == .mouseMoved { return }
        let now = ProcessInfo.processInfo.systemUptime
        let revisions = advance()
        dwell.reset(at: now)
        // Keys and drag movement invalidate stale scenes, without reading or retaining their content.
        guard type == .leftMouseDown || type == .rightMouseDown || type == .scrollWheel else {
            if let finished = scroll.take() { emit(finished) }
            return
        }
        let point = event.location
        let window = route.window(at: point, in: InteractionWindowReader.windows(excluding: excludedPID))
        let kind: InteractionEvent.Kind = type == .scrollWheel ? .scroll : type == .rightMouseDown ? .rightClick : .click
        let input = InteractionEvent(
            kind: kind, timestamp: Date(), startedAt: now, endedAt: now,
            precedingRevision: revisions.0, revision: revisions.1, point: point,
            window: window, processID: window?.processID ?? route.targetProcessID,
            deltaX: kind == .scroll ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) : 0,
            deltaY: kind == .scroll ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) : 0,
            sourceProcessID: Int32(clamping: event.getIntegerValueField(.eventSourceUnixProcessID))
        )
        if kind == .scroll {
            if let finished = scroll.append(input) { emit(finished) }
        } else {
            if let finished = scroll.take() { emit(finished) }
            emit(input)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, pointer in
        if let pointer {
            Unmanaged<TapContext>.fromOpaque(pointer).takeUnretainedValue().receive(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }
}
