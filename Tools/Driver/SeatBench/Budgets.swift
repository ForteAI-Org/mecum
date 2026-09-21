//
//  Budgets.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// Budget is the single place the numbers of spec section 8 live as typed
/// constants, so the benchmark and any performance test read the same source
/// instead of two drifting copies.
///
/// A budget here is a contract, not a target: a violation is a failure the
/// driver exits non zero on. Renegotiating one takes a measurement, not an
/// edit.
nonisolated enum Budget {

    /// Heap allocations attributable to the fence callback, in every scenario:
    /// at rest, with an anchor in flight, with an audit recording. Zero: the two
    /// that the obvious shape costs are designed out of the callback.
    static let fenceCallbackAllocations = 0

    /// The callback's p99, in nanoseconds. It measures 42 ns at rest, so this is
    /// three orders of magnitude of headroom and a regression is
    /// visible long before it becomes a violation.
    static let fenceCallbackP99Nanoseconds: Double = 50_000

    /// The callback's absolute ceiling, in nanoseconds. Reported rather than
    /// gated: the maxima of 7 to 38 us are scheduler preemption of the measuring
    /// loop, not work the callback did, and gating on them would fail the build
    /// for someone else's CPU time.
    static let fenceCallbackCeilingNanoseconds: Double = 1_000_000

    /// The p99 of the clamp branch, in nanoseconds, **with the cursor really
    /// warped**.
    ///
    /// It is a separate constant from the callback's own p99 because the branch
    /// ends in `CGWarpMouseCursorPosition`, a synchronous window server round
    /// trip, and the 50 us was written for a path with no round trip in it. The
    /// branch runs only while the person is pushing the pointer at the edge of
    /// their own displays, never on the steady state path, and the hard limit
    /// it must respect is the 1 ms ceiling below. With a real warp the branch
    /// measures 13,8 us at p99, of which 125 ns is the kit's own share.
    static let fenceClampP99Nanoseconds: Double = 500_000

    /// Heap allocations attributable to the kit's ownership checks in one
    /// guarded identity resolution, after subtracting a measured control that
    /// performs the same two documented `GetProcessPID` mappings. Zero. The raw
    /// identity and control allocations remain in the report; geometry and
    /// CoreGraphics event allocations are separate and are not claimed as zero.
    static let sendClickAllocations = 0

    /// The attributable p95 of one `send` of a click, in nanoseconds, settle
    /// and Preparation excluded: the whole send minus a control that builds and
    /// posts the same two events.
    ///
    /// The current guarded coordinate path includes two complete geometry
    /// readings. On macOS 27.0 build 26A428 on Mac16,1, three release runs
    /// measured attributable p95s of 443 250, 403 917 and 410 458 ns; their
    /// median is 410 458 ns. The budget is rounded above twice that median and
    /// remains below the specification's absolute 1 ms ceiling.
    static let sendClickNanosecondsP95: Double = 850_000

    static let sendClickRegressionFloorNanoseconds: Double = 25_000

    /// Allocations CoreGraphics charges for building one event: six is the
    /// ceiling, a click has been measured at five, and this kit measures two.
    static let makeEventsAllocationsPerEvent: Double = 6

    /// One whole Preparation cycle, in nanoseconds at p95, settle excluded:
    /// three records applied and one restored.
    ///
    /// Spec section 8 says 100 us, on an estimate nobody had timed, and the
    /// measurement does not fit inside it. A cycle
    /// is **four window server round trips**, measured at 133 to 147 us at p50
    /// and 213 to 242 us at p95, of which the restore alone is 26 us at p50.
    /// The budget is therefore twice the measured p95, and what has to be
    /// reconciled in the spec is the 100 us, written for two records nobody had
    /// timed.
    static let preparationNanosecondsP95: Double = 500_000

    /// Virtual display setup, in nanoseconds at p95: create, wait for
    /// `NSScreen`, attach the topology, verify. **Without a settle**: with a
    /// deliberate 300 ms wait in the middle it measured 646 to 707 ms, and this
    /// budget is written on the premise that the wait comes out. If it had to
    /// stay, the number would be 1 s.
    static let displaySetupNanosecondsP95: Double = 800_000_000

    /// Virtual display removal, in nanoseconds at p95: from releasing the
    /// private object to the id being absent from `CGGetOnlineDisplayList`,
    /// which measures 78 to 94 ms.
    static let displayTeardownNanosecondsP95: Double = 200_000_000

    /// Bringing a stashed window on stage, in nanoseconds at p95, measured on
    /// Chrome at 532 ms. Not measured by this driver: it needs a
    /// window Stage Manager has actually stashed, and that needs a second
    /// cooperative process.
    static let stageNanosecondsP95: Double = 1_000_000_000

    /// The absolute floor under which a display regression is noise, in
    /// nanoseconds.
    ///
    /// A removal is tens of milliseconds and its p50 wanders by about 11 ms
    /// between runs on the reference machine, so the 10 % rule alone would call
    /// scheduler noise a regression. A regression has to be over the percentage
    /// **and** over 25 ms, the same shape the fence benchmark uses with its own
    /// floor.
    static let displayRegressionFloorNanoseconds: Double = 25_000_000

    // MARK: The Monitor, spec section 8

    /// The Monitor's CPU budget at 1920x1080: eight percent of one core,
    /// **net** of the animated scene that produces the frames. The zero-copy
    /// pipeline measures 6,2 % net at 60 fps and 5,8 % at 30,
    /// against 42,2 % for the `CGImage` pipeline the kit does not ship.
    static let monitorNetCpuPercent = 8.0

    /// The same at the 120 level, which spec section 8 calls provisional at
    /// twelve percent: twice the frames through the same zero-copy path, and
    /// the level is only measurable at all against a producer that really
    /// changes 120 times a second.
    static let monitorNetCpuPercentAt120 = 12.0

    static func monitorNetCpuPercent(atFrameRate rate: Int) -> Double {
        rate == 120 ? monitorNetCpuPercentAt120 : monitorNetCpuPercent
    }

    /// Callback to screen at p95, in nanoseconds: from the frame entering the
    /// kit's ScreenCaptureKit callback to its surface being in
    /// `CALayer.contents`: 0,46 ms at p50 and 0,96 ms at p95 at 60 fps, against
    /// 2,5 ms and 6,1 ms for the `CGImage` pipeline.
    static let monitorLatencyNanosecondsP95: Double = 2_000_000

    /// Callback to screen at p95 at the **120 level**, in nanoseconds.
    ///
    /// Spec section 8 gives the 120 row a CPU budget and nothing else, and the
    /// 2 ms above is written on the "monitor 1920x1080 at 30 and 60 fps" row:
    /// applying it at 120 was this driver's own over-reach. This number comes
    /// from the first run with content that really changes 120 times a second:
    /// p50 2,42 ms, p95 6,77 ms, p99 8,91 ms over
    /// 2390 frames, with 120 frames a second produced and 0,4 % coalesced.
    ///
    /// It is seven times the 60 Hz figure for a structural reason worth
    /// knowing: presentation is one main thread hop per frame, and at a 8,3 ms
    /// frame interval the hops queue behind each other. Fourteen milliseconds
    /// is twice the measured p95, which is the rule for a new budget.
    static let monitorLatencyNanosecondsP95At120: Double = 14_000_000

    static func monitorLatencyNanosecondsP95(atFrameRate rate: Int) -> Double {
        rate == 120 ? monitorLatencyNanosecondsP95At120 : monitorLatencyNanosecondsP95
    }

    /// Net footprint of the Monitor, in bytes: twelve megabytes. The surface
    /// pipeline measures 7 MB net and the `CGImage` one 78 MB.
    static let monitorNetFootprintBytes = 12.0 * 1_048_576

    /// The share of frames the newest-wins slot may throw away: one percent.
    /// No configuration measured so far has thrown away a single one.
    static let monitorCoalescenceRate = 0.01

    /// The absolute floor under which a Monitor latency regression is noise, in
    /// nanoseconds. The measurement is a main-thread hop of a few hundred
    /// microseconds, and it moves with whatever else the person's Mac is doing,
    /// so the 10 % rule alone would report a regression on someone else's CPU
    /// time.
    static let monitorRegressionFloorNanoseconds: Double = 250_000

    /// The same floor at the **120 level**, in nanoseconds: one frame interval.
    ///
    /// Presentation is one main thread hop per frame and the interval at 120 Hz
    /// is 8,3 ms, so the hops queue behind each other and how deep the queue
    /// gets is a property of what else wants the main thread. Measured across
    /// four runs on the same machine and the same build: a p50 of 0,55 ms, then
    /// 2,83, then 2,00, then 2,57, all of them with the producer at 132 frames a
    /// second and the stream applying 111. A five-fold spread is not a
    /// regression to detect, it is the same behaviour scheduled differently, and
    /// anything inside one frame interval is inside that spread. What gates this
    /// level is its CPU and the 14 ms p95 above.
    static let monitorRegressionFloorNanosecondsAt120: Double = 8_333_333

    static func monitorRegressionFloorNanoseconds(atFrameRate rate: Int) -> Double {
        rate == 120 ? monitorRegressionFloorNanosecondsAt120 : monitorRegressionFloorNanoseconds
    }

    // MARK: The session layer, spec section 8

    /// A seat at rest: display, fence and heartbeat, no Monitor. The median CPU
    /// per second as a percentage of one core, **net** of the same process
    /// pumping the same event loop with no host at all.
    ///
    /// A seat with a 20 ms watchdog measured 0,024 % at the median, so this
    /// budget has room; the point of measuring it is the engine change, from
    /// fifty wake-ups a second to one.
    static let seatIdleMedianCpuPercent = 0.1

    /// The same, at p95: a single beat that lands next to something else the
    /// system was doing may cost more, and one second in twenty is allowed to.
    static let seatIdleP95CpuPercent = 1.0

    /// Wake-ups a second, net of the control. Five, against a heartbeat of one
    /// and a display reconfiguration callback that fires only when the person's
    /// arrangement changes.
    static let seatIdleWakeupsPerSecond = 5.0

    /// Attributable footprint of a live seat: four megabytes, measured as the
    /// high water mark after `start` minus the one before it, never an
    /// instantaneous delta. It measures 1,2 MB.
    static let seatIdleFootprintBytes = 4.0 * 1_048_576

    // MARK: The window watch, ticket MW-02

    /// A seat that follows its applications' windows, **net of the same seat
    /// with the watch off**, at the median: a percentage of one core.
    ///
    /// The control is the expensive half of the pair and that is the point.
    /// Both halves bring up a virtual display, install the fence, adopt this
    /// process's own window and beat the same heartbeat for the same length of
    /// time; the only difference is `followsNewWindows`. So what is reported is
    /// the pass and not the seat, which is the rule a benchmark without a
    /// subtracted control breaks.
    ///
    /// Measured on macOS 27.0 build 26A428 on Mac16,1, three release runs of
    /// 60 s a side: net medians of 0,092 %, 0,073 % and 0,053 % against a
    /// control that measured 0,046 %, 0,045 % and 0,078 % on its own. The
    /// median of the three is 0,073 % and the budget is rounded above twice it.
    static let windowWatchMedianCpuPercent = 0.2

    /// The same at p95. A pass that lands next to something else the system was
    /// doing costs more, and one second in twenty is allowed to: the same three
    /// runs measured 0,142 %, 0,402 % and 0,238 %, a threefold spread for the
    /// same work scheduled differently. The budget is rounded above twice the
    /// worst of them, and lands on the number `seatIdleP95CpuPercent` already
    /// allows one second in twenty to cost.
    static let windowWatchP95CpuPercent = 1.0

    /// Wake-ups a second the watch may add, net of the same seat with it off.
    /// It adds no timer: it rides the heartbeat that already beats once a
    /// second, plus an accessibility notification that fires only when an
    /// application creates a window, so at rest the budget is about the pass
    /// and not about a new clock. The three runs measured 0,300, 0,165 and
    /// 0,099 net against a control of about 2,1 a second.
    static let windowWatchWakeupsPerSecond = 1.0

    /// Window server passes a second while nothing is happening. The three runs
    /// each measured 0,967, which is the heartbeat: a burst only follows a
    /// wake-up, and at rest there is none. Two, so that a beat landing either
    /// side of a sample boundary is not a violation.
    static let windowWatchScansPerSecond = 2.0

    /// From a recoverable Issue to the seat being `ready` again, at p95: two
    /// seconds.
    ///
    /// The floor is structural and worth knowing when reading the number: the
    /// recovery reads the window server every 250 ms and needs two agreeing
    /// readings, so nothing can come back in less than half a second.
    static let recoveryNanosecondsP95: Double = 2_000_000_000

    /// How much worse than the saved baseline a latency may get before it
    /// counts as a regression, on p95.
    static let regressionTolerance = 0.10

    // MARK: The focus recovery refresh

    // No constant on purpose: `SeatSessionBench.runFocusRefresh` reports the
    // once-a-second refresh's net cost and gates on nothing until a run decides.
}
