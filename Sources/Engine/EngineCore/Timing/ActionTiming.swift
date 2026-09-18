//
//  ActionTiming.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// ActionTiming is every pause an action pays, in one place, each carrying the measurement that set
/// it. The engine never sleeps a literal.
///
/// The click settle is the maximum of what the measured surfaces needed, not the average: a Finder
/// list was not final at the first capture (169 ms showed the selection highlight, 352 ms the
/// loaded directory) while a Qt preferences window was final at 134 ms and a text view at 119 ms.
/// An adaptive wait was measured and rejected: proving a window has stopped changing costs two
/// captures, more than the sleep it would replace. Anything here that changes must change with a
/// printed settle run in the commit message.
public struct ActionTiming: Sendable, Equatable {

    /// After a click, before the verifying re-perception.
    public var clickSettle: Duration = .milliseconds(300)
    /// After raising an application that was not in front, before the gesture.
    public var activateSettle: Duration = .milliseconds(200)
    /// Pop-up keyboard paths: after typing an item's first word.
    public var popupType: Duration = .milliseconds(250)
    /// Pop-up keyboard paths: after an arrow key.
    public var popupArrow: Duration = .milliseconds(250)
    /// After the Return that commits a pop-up selection, before judging it.
    public var popupCommit: Duration = .milliseconds(350)
    /// After the Escape that dismisses a pop-up the target is not in.
    public var popupDismiss: Duration = .milliseconds(250)

    public static let standard = ActionTiming()

    public init() {}
}
