import Foundation

/// WHICH WAY IS UP — the wheel sign the scroll engine posts, measured instead of assumed.
///
/// A synthetic `wheel1` line has no absolute meaning. The textbook convention (positive = content
/// down = the view scrolls UP) is what this codebase was written against, and it is WRONG on a Mac with
/// natural scrolling — which is every Mac out of the box. Measured 2026-08-21 with `locator
/// debug-scroll`: on a Finder list resting at its TOP, `--lines=10` moved it (so POSITIVE lines scroll
/// the view DOWN) while `--lines=-10`, which the engine called "down", moved nothing at all. So
/// `scroll(direction:"down")` physically scrolled up, and every "already at the TOP/BOTTOM" verdict was
/// inverted with it — silently, because the movement verdict only ever asked *whether* the pixels
/// changed, never which way.
///
/// The fix is not to read `com.apple.swipescrolldirection`: that answers for the machine but not for an
/// app that inverts the wheel internally, and the measurement is free anyway — the two frames the
/// movement verdict already compares are the two frames the slide alignment needs
/// (`ScrollProbe.contentSlidePx`). Every burst therefore checks the sign it got and teaches it here.
///
/// The horizontal axis has done this since it shipped (`HorizontalScroller.contentSlidePx` + the
/// self-calibrating probe in the scroll verb), paying a 2-tick probe on every call. This is the same
/// honesty for the vertical axis, paid once per app instead of once per step.
public enum WheelPolarity {
    /// The sign of a `wheel1` value that scrolls a view UP, before anything has been measured.
    ///
    /// −1, not the textbook +1: natural scrolling is ON by default on every Mac, and that is what was
    /// measured here. A machine with it switched OFF self-corrects on its first burst — which is the
    /// point of measuring — but the default should be right for the machine most people have.
    public static let assumedUpSign = -1

    // MARK: the sign contract (pure — no I/O, so the burst can be reasoned about without a screen)

    /// +1 or −1: the sign a `wheel1` value needs to scroll the view the way `requestedTicks` asks
    /// (negative = the caller asked to scroll the view UP, positive = DOWN) on a machine whose up-sign
    /// is `upSign`. This is the ONE place a direction becomes a wheel sign — the vertical engine used to
    /// hold two contradictory conventions (`PaneScroller`: "up = +1"; `OpaqueScrollDriver`: "down = +1"),
    /// which is how one of them was quietly wrong on every Mac.
    public static func sign(requestedTicks: Int, upSign: Int) -> Int {
        requestedTicks < 0 ? upSign : -upSign
    }

    /// The `wheel1` lines to post per event for a request of `requestedTicks`. Lines are clamped to a
    /// sane burst: at least 1 (a zero-line event scrolls nothing) and at most 6 (beyond that one event
    /// overshoots a viewport).
    public static func wheel1(requestedTicks: Int, upSign: Int) -> Int32 {
        Int32(max(1, min(6, abs(requestedTicks)))) * Int32(sign(requestedTicks: requestedTicks, upSign: upSign))
    }

    /// Did the view go the way the caller ASKED? `viewWentUp` is whatever witness could read the
    /// direction — the pane's own named rows (`UserScrollCalibration.rigidShift`) or, for a pane with no
    /// labels, its pixels (`ScrollProbe.contentSlidePx`). nil in, nil out: an unread direction teaches
    /// nothing, and guessing is how a wheel sign gets learned backwards.
    public static func requestWasHonoured(requestedTicks: Int, viewWentUp: Bool?) -> Bool? {
        guard let viewWentUp else { return nil }
        return viewWentUp == (requestedTicks < 0)
    }

    /// The up-sign PROVEN by one burst: the sign it was posted with if the view went where it was
    /// asked, the opposite if it went the other way. nil when the direction could not be read.
    public static func provenUpSign(postedWith upSign: Int, requestedTicks: Int, viewWentUp: Bool?) -> Int? {
        guard let honoured = requestWasHonoured(requestedTicks: requestedTicks, viewWentUp: viewWentUp)
        else { return nil }
        return honoured ? upSign : -upSign
    }

    // MARK: what is remembered

    /// The up-sign to post with for `app` — its own measured sign, else this machine's, else the
    /// assumed default.
    public static func upSign(app: String, axis: ScrollAxis = .vertical,
                              memory: LocatorMemory = .shared) -> Int {
        guard let remembered = memory.wheelPolarity(app: app, axis: key(axis)) else { return assumedUpSign }
        // A READ-HIT ONLY WHEN IT CHANGED THE BURST. A remembered sign that agrees with the assumed
        // default posts byte-identical events, so counting it would credit the ledger for agreeing —
        // and the whole point of the two numbers is to tell agreement from usefulness.
        if remembered != assumedUpSign { memory.noteUsefulRead(.wheelPolarity, app: app) }
        return remembered
    }

    /// Has the direction been asked in THIS app? A shared machine hint cannot waive this check. What
    /// gates the one-time calibration nudge: a full burst is bigger than a viewport, so it leaves no
    /// overlap for any direction witness to read, and the sign has to be learned from a small deliberate
    /// nudge instead. Each app pays once; a stored unreadable marker prevents repeated futile probes.
    public static func isKnown(app: String, axis: ScrollAxis = .vertical,
                               memory: LocatorMemory = .shared) -> Bool {
        let asked = memory.wheelPolarityAsked(app: app, axis: key(axis))
        // Remembering that the question was asked skips a deliberate nudge AND the scene build that
        // reads it — the largest single saving any of these memories makes. A "no" changes nothing: the
        // calibration is what happens anyway.
        if asked { memory.noteUsefulRead(.wheelPolarity, app: app) }
        return asked
    }

    /// Record that nothing here could name a direction — no rows the labels agree on, no pixels the
    /// alignment will sign. The default sign keeps being used (it is right on a stock Mac) and the
    /// calibration is not paid again for this app.
    public static func learnUnreadable(app: String, axis: ScrollAxis = .vertical,
                                       memory: LocatorMemory = .shared) {
        memory.recordWheelPolarityUnreadable(app: app, axis: key(axis))
    }

    /// Record a MEASURED sign. Skips the write when it only re-confirms what is already remembered,
    /// so the happy path costs no DB write per scroll.
    public static func learn(app: String, axis: ScrollAxis = .vertical, upSign: Int,
                             memory: LocatorMemory = .shared) {
        if memory.wheelPolarity(app: app, axis: key(axis), includingFallback: false) == upSign {
            memory.noteUsefulRead(.wheelPolarity, app: app)   // the write this read spared
            return
        }
        memory.recordWheelPolarity(app: app, axis: key(axis), upSign: upSign)
    }

    /// The axis column the living memory keys on — the same "v"/"h" the scroll-pane rows use.
    private static func key(_ axis: ScrollAxis) -> String { axis == .vertical ? "v" : "h" }
}
