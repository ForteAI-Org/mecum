//
//  PreviewRestPlan.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

/// When the window stream nobody uses lowers its rate, and to what (ADR 0036).
///
/// A running stream of an unchanged window still delivers about 29 complete frames a second on
/// macOS 27, and that is most of an open session's CPU at rest. While no layer shows the stream
/// and nothing used it for `delay`, `PreviewStreamController` asks it for `framesPerSecond`
/// instead of 30. The next use wakes it, and a request meanwhile waits for a frame displayed after
/// its own instant, within a bound, before it takes a Still: never an older frame.
struct PreviewRestPlan: Equatable {

    /// How long the stream goes unused before it rests: 2.5 s. An act cycle's own gaps (observe,
    /// Turn, Command, settle, observe) are tens to hundreds of milliseconds, so none rests inside
    /// a tool call; a model choosing its next call usually takes longer, which is the rest wanted.
    var delay: Duration = .milliseconds(2_500)

    /// The rate at rest, 1 frame a second: the lowest whole rate `SeatCaptureConfiguration` can
    /// ask for, and the stream keeps running, so waking is a configuration update and not a start.
    var framesPerSecond: Int = 1
}

/// PreviewActivity is what used the preview's stream, which ends its rest and restarts its delay.
/// The case names the rest's end in the phase build (`preview.rest`).
enum PreviewActivity: String {

    /// An observation or a settle asked for a frame.
    case frameRequest

    /// An observation was delivered and the preview followed it.
    case observation

    /// The window was adopted and its stream started.
    case adoption

    /// A Turn was acquired through the driver.
    case turn

    /// A Command was sent through the driver.
    case command

    /// A layer was attached or detached: the person opened or closed the picture.
    case layer

    /// The preview was pinned to the display or given back to the window.
    case pin
}
