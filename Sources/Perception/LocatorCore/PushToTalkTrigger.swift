import Foundation

/// The push-to-talk KEY LOGIC, with no audio in it: decides when a right-shift hold means "start
/// listening" and when a release means "send" vs "discard". Pure and unit-tested, because the guards
/// are the whole feature — a trigger that fires while you type SHIFT+letter would open the microphone
/// during ordinary work, and one that misses a real hold makes the feature feel broken.
///
/// Two guards:
/// - **min hold**: a right-shift tap shorter than `minHold` is typing, not intent.
/// - **chord**: any other key pressed during the hold means SHIFT+something — cancel, and if listening
///   already began, discard what was heard rather than sending a fragment.
public struct PushToTalkTrigger: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case startListening
        case sendTranscript      // clean release after a real hold
        case discardTranscript   // a chord broke the hold mid-listen
    }

    public var minHold: TimeInterval
    private var pressedAt: Date?
    private var chordBroken = false
    private var listening = false

    public init(minHold: TimeInterval = 0.3) { self.minHold = minHold }

    public var isListening: Bool { listening }

    /// The right shift went down (`down: true`) or up. Release decides send vs nothing.
    public mutating func rightShift(down: Bool, at now: Date) -> Action {
        if down {
            pressedAt = now
            chordBroken = false
            return .none                    // arming is deferred — see `armIfHeld`
        }
        pressedAt = nil
        guard listening else { chordBroken = false; return .none }
        listening = false
        let action: Action = chordBroken ? .discardTranscript : .sendTranscript
        chordBroken = false
        return action
    }

    /// Any OTHER key went down. During a hold this is a typing chord.
    public mutating func otherKeyDown() -> Action {
        guard pressedAt != nil else { return .none }
        chordBroken = true
        guard listening else { return .none }
        listening = false
        return .discardTranscript
    }

    /// Called after `minHold` has elapsed (the caller schedules it on press): start listening only if
    /// the key is STILL held and no chord broke it.
    public mutating func armIfHeld(at now: Date) -> Action {
        guard let pressedAt, !chordBroken, !listening,
              now.timeIntervalSince(pressedAt) >= minHold - 0.001 else { return .none }
        listening = true
        return .startListening
    }
}
