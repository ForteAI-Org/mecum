//
//  TextLimits.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

/// TextLimits is the most text one Command may carry, and both numbers are the
/// **largest value anybody measured**, not a round number and not a guess.
///
/// The rule is the one the rest of this kit follows: it does not post what
/// nobody measured. Above these, a Command refuses, and the caller either cuts
/// the text itself or hands it to `AgentSeat.sendText`, which cuts it at
/// grapheme cluster boundaries and re-verifies the recipient between pieces.
///
/// They are separate numbers in separate units because the two paths cost
/// different things. `TextDeliveryLimits` is a different question again: it is
/// how much one *chunk* should carry, which is a policy about how long a single
/// Command may hold a target's exclusion, and it sits below these.
public enum TextLimits {

    /// The most UTF-16 code units one `.insertText` may carry.
    ///
    /// 8192 is where the evidence stops, not where delivery was seen to break:
    /// measured on macOS 27.0 into background windows, 8192 clusters of ASCII
    /// arrived on both target families, 2 events, 383 ms on a browser renderer
    /// and at most 295 ms on a native text control. Nobody has asked for more,
    /// so more is unmeasured and refused. Ticket B4's sweep is what moves this.
    public static let maximumInsertedCodeUnits = 8192

    /// The most grapheme clusters one `.text` may carry.
    ///
    /// The same ceiling in the other unit, and for a sharper reason: a typed
    /// string is two events per cluster inside **one** atomic Command, so 8192
    /// clusters are 16384 events posted in an uninterruptible loop that holds
    /// the target's exclusion for every other driver in the process. The same
    /// measurement put that at 5,4 s on a browser renderer and 92 s on a native
    /// text control. A caller wanting more should be cutting it up, which is
    /// what `sendText` does.
    public static let maximumTypedClusters = 8192
}
