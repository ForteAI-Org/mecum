//
//  KeyPhase.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

/// KeyPhase is which part of a key press one Command carries, and it exists so
/// that separating a down from an up does not need two more cases in the
/// Command vocabulary.
///
/// `.press` is what a bare key has always been and stays the default, so a
/// caller that never asked the question keeps the behaviour it had. The other
/// three are the ones a caller has to choose deliberately, and two of them
/// leave something behind: a `.down` without its `.up` is a key the session
/// holds until the Turn is released.
public enum KeyPhase: Sendable, Equatable {

    /// One down and one up, the atomic press.
    case press

    /// A down alone. The session holds the key, and `InputReceipt.heldAfter`
    /// says so on every receipt until an `.up` or the Turn's release.
    case down

    /// An up alone.
    case up

    /// `count` further key downs, which is what a held key produces. It carries
    /// no down of its own and no up: a repeat is what happens between them, so
    /// the caller sends `.down`, then this, then `.up`.
    ///
    /// **They are ordinary key downs and the autorepeat field is not set on
    /// them**, which is a measurement and not a preference. On 26A428 an event
    /// carrying that field was not delivered to either target family at all:
    /// zero arrived, at every count and every interval tried, while ordinary
    /// presses arrived every time. So what a target sees here is `count`
    /// discrete presses rather than a run marked as a repeat, and anything that
    /// reads the field, or `event.repeat` in a web page, will not see one.
    ///
    /// The count is bounded because the whole Command is atomic: the driver
    /// holds the actor and the PID exclusion in an uninterruptible wait for its
    /// entire duration, so a large count blocks every other driver aimed at the
    /// same process for as long as it runs.
    case repeated(count: Int)

    /// The largest `repeated` count the driver accepts.
    ///
    /// **Provisional.** It is the count that keeps one Command under roughly a
    /// second of held exclusion at the system's own repeat interval of about
    /// 33 ms, which is a reasoning about the cost and not a measurement of what
    /// a target tolerates. Ticket A3's sweep replaces it with a measured number.
    public static let maximumRepeatCount = 32

    /// How many key events this phase produces, which is what a receipt's
    /// `eventCount` has to agree with.
    public var eventCount: Int {
        switch self {
            case .press               : 2
            case .down, .up           : 1
            case .repeated(let count) : count
        }
    }
}
