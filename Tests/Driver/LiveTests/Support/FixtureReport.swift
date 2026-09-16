//
//  FixtureReport.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import Foundation

/// FixtureReport is the contract between this suite and an instrumented target
/// the kit does not own.
///
/// A consumer that wants its own application driven by the Live tier launches
/// nothing: the suite launches the binary named by `AGENTSEAT_FIXTURE_APP` with
/// `--session <token>` and reads this JSON object out of the file the token
/// names. The consumer's own state object may carry any number of extra keys,
/// which are ignored here: only what the matrix asserts on is declared.
///
/// The path is `/tmp` and not `TMPDIR` on purpose: `TMPDIR` is per process on
/// macOS, so two processes never agree on it.
nonisolated struct FixtureReport: Decodable {

    static func url(sessionToken: String) -> URL {
        URL(fileURLWithPath: "/tmp/agentseat-fixture-\(getuid())-\(sessionToken).json")
    }

    /// Reads the report, refusing one that is stale: a target that stopped
    /// publishing is a target that stopped answering, and the last file it left
    /// behind is not evidence about the action just posted.
    static func read(sessionToken: String, maximumAge: TimeInterval = 3) -> FixtureReport? {
        guard
            let data   = try? Data(contentsOf: url(sessionToken: sessionToken)),
            let report = try? JSONDecoder().decode(FixtureReport.self, from: data),
            report.sessionToken == sessionToken,
            Date().timeIntervalSince1970 - report.writtenAt <= maximumAge
        else {
            return nil
        }
        return report
    }

    let sessionToken       : String
    let writtenAt          : TimeInterval

    // Identity and geometry, in AppKit coordinates as the target sees them.
    let processID          : Int32
    let windowNumber       : Int
    let windowX            : Double
    let windowY            : Double
    let windowWidth        : Double
    let windowHeight       : Double
    let applicationIsActive: Bool
    let windowIsKey        : Bool

    // The counters the matrix compares before and after each action.
    let buttonPressCount      : Int
    let textValue             : String

    /// How many times the target's own editor said its text changed. It is the
    /// counter and not the string that says how much text arrived: a framework
    /// text control reports a value that lags behind what its field editor has
    /// already applied, so the string can be short while the edits are all in.
    let textChangeCount       : Int

    let sliderValue           : Double
    let scrollOffsetY         : Double
    let scrollMaximumOffsetY  : Double
    let metalFrame            : UInt64
    let syntheticMouseDownCount: Int
    let syntheticMouseDragCount: Int
    let syntheticMouseUpCount  : Int
    let syntheticScrollCount   : Int

    // Where to aim, in Quartz coordinates, and the target's own verdict on
    // whether each of those points hit tests to the control it belongs to.
    let buttonQuartzX        : Double
    let buttonQuartzY        : Double
    let sliderStartQuartzX   : Double
    let sliderStartQuartzY   : Double
    let sliderEndQuartzX     : Double
    let sliderEndQuartzY     : Double
    let scrollQuartzX        : Double
    let scrollQuartzY        : Double

    /// True only when every point above is inside the window and reaches its own
    /// control through the content view's hit test. This is the assertion that
    /// replaced looking at the window.
    let controlsAreHitTestable: Bool

    /// Which control each published point actually reached, control by control,
    /// so a false verdict names the view in the way.
    let controlHitTestReport  : String

    // The window local vertical position of the two controls that used to fall
    // off the window: a negative value is the old defect itself.
    let sliderStartWindowY   : Double
    let scrollWindowY        : Double
    let metalHeight          : Double

    // The line under a failed row.
    let lastEvent            : String
    let lastMouseWindowNumber: Int
    let lastMouseHitView     : String
    let lastScrollHitView    : String

    // MARK: The shortcut channel, ticket A7

    /// Every field below is optional on purpose. `JSONDecoder` fails the whole
    /// decode on one missing required key, so a non-optional addition here
    /// would make an older fixture binary unreadable and take every AppKit row
    /// of the matrix down with it. Absent means the fixture does not publish
    /// this yet, which the harness already reports as `countersUnreadable` and
    /// never as a pass.
    let lastShortcutDelivered : String?
    let lastShortcutEffect    : String?
    let shortcutEffectCount   : Int?

    /// The selection, for the rows whose effect is a selection: Command and A
    /// widens it, Option and the right arrow moves its start by a word.
    let selectedRangeLocation : Int?
    let selectedRangeLength   : Int?

    /// `NSPasteboard.general.changeCount`, a monotonic integer. The copy row
    /// reads it and nothing else: it says something was put on the clipboard
    /// without reading anything of the person's.
    let pasteboardChangeCount : Int?

    /// How many times the fixture's own `cancelOperation:` ran, which is what
    /// an Escape reaches through the responder chain.
    let cancelCount           : Int?

    /// How many windows the fixture owns. Command and Shift and S opens a save
    /// panel, which changes nothing a text field could report, so the oracle is
    /// that a window appeared.
    let ownedWindowCount      : Int?

    /// Every key down the target received, autorepeat ones included. It is the
    /// only counter that answers "did this event arrive" for a key that changes
    /// no text, which is what the repeat sweep asks.
    let keyDownCount          : Int?

    /// The composition the target is holding, as a length in UTF-16 units, and
    /// the string it marks when it holds one.
    ///
    /// A target that never composes publishes zero and an empty string, or
    /// omits both: these are optional like every other key a consumer's own
    /// application may not have. The composition row is skipped when they are
    /// absent, and says so.
    let markedTextLength      : Int?
    let compositionText       : String?
    let compositionCount      : Int?
}
