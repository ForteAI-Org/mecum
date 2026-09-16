//
//  main.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Darwin
import Foundation

// The measurement driver. One benchmark per subcommand, each of them a gate: it
// exits non zero when a budget of spec section 8 is violated, so `make bench`
// can be part of a build rather than something someone reads.
//
//   SeatBench fence-callback    [iterations] [out.json] [baseline-directory]
//   SeatBench display-lifecycle [cycles]     [out.json] [baseline-directory]
//   SeatBench send-click        [iterations] [out.json] [baseline-directory]
//   SeatBench input-trace-overhead [iterations] [out.json]

let arguments = CommandLine.arguments
let benchmark = arguments.count > 1 ? arguments[1] : FenceCallbackBench.name

/// One optional path argument. An empty one means "skip this", so a caller can
/// ask for a baseline comparison without also writing a report.
func argument(_ index: Int) -> String? {
    guard arguments.count > index, !arguments[index].isEmpty else { return nil }
    return arguments[index]
}

switch benchmark {
case FenceCallbackBench.name:
    let iterations = arguments.count > 2 ? (Int(arguments[2]) ?? 200_000) : 200_000
    let output     = argument(3)
    let baseline   = argument(4)
    exit(FenceCallbackBench.run(
        iterations       : iterations,
        outputPath       : output,
        baselineDirectory: baseline
    ) ? 0 : 1)

case DisplayLifecycleBench.name:
    // A real display appears on the person's Mac for about two seconds per
    // cycle, so the default is the smallest count a p95 means anything for.
    let cycles   = arguments.count > 2 ? (Int(arguments[2]) ?? 5) : 5
    let output   = argument(3)
    let baseline = argument(4)
    exit(DisplayLifecycleBench.run(
        cycles           : cycles,
        outputPath       : output,
        baselineDirectory: baseline
    ) ? 0 : 1)

case FenceClampBench.name:
    let iterations = arguments.count > 2 ? (Int(arguments[2]) ?? 20_000) : 20_000
    let output     = argument(3)
    let baseline   = argument(4)
    exit(FenceClampBench.run(
        iterations       : iterations,
        outputPath       : output,
        baselineDirectory: baseline
    ) ? 0 : 1)

case SendClickBench.name:
    let iterations = arguments.count > 2
        ? (Int(arguments[2]) ?? SendClickBench.defaultIterations)
        : SendClickBench.defaultIterations
    let output     = argument(3)
    let baseline   = argument(4)
    exit(SendClickBench.run(
        iterations       : iterations,
        outputPath       : output,
        baselineDirectory: baseline
    ) ? 0 : 1)

case InputTraceOverheadBench.name:
    let iterations = arguments.count > 2 ? (Int(arguments[2]) ?? 100_000) : 100_000
    exit(InputTraceOverheadBench.run(iterations: iterations, outputPath: argument(3)) ? 0 : 1)

case MonitorBench.thirtyName, MonitorBench.sixtyName, MonitorBench.oneHundredTwentyName:
    // A real display and a real stream live on the person's Mac for the whole
    // run, and the control has to run for the same length, so the default is
    // the shortest window a 1 Hz CPU sample makes a mean out of.
    let seconds  = arguments.count > 2 ? (Double(arguments[2]) ?? 20) : 20
    let output   = argument(3)
    let baseline = argument(4)
    let requestedRate = switch benchmark {
    case MonitorBench.thirtyName          : 30
    case MonitorBench.oneHundredTwentyName: 120
    default                               : 60
    }
    exit(MonitorBench.run(
        framesPerSecond  : requestedRate,
        seconds          : seconds,
        outputPath       : output,
        baselineDirectory: baseline
    ) ? 0 : 1)

case StageBench.name:
    // A real display and a second process live on the person's Mac for the
    // whole run, and every cycle waits for Stage Manager's animation, so the
    // default is the smallest count a p95 means anything for.
    let stageCycles = arguments.count > 2 ? (Int(arguments[2]) ?? 5) : 5
    let output      = argument(3)
    let baseline    = argument(4)
    exit(StageBench.run(
        cycles           : stageCycles,
        outputPath       : output,
        baselineDirectory: baseline
    ) ? 0 : 1)

case SeatSessionBench.idleName:
    // Five minutes is what the budget's median and p95 are written over. A
    // shorter window is for a smoke run, and it says so in the sample count.
    let seconds  = arguments.count > 2
        ? (Double(arguments[2]) ?? SeatSessionBench.defaultIdleSeconds)
        : SeatSessionBench.defaultIdleSeconds
    let output   = argument(3)
    let baseline = argument(4)
    exit(SeatSessionBench.runIdle(
        seconds          : seconds,
        outputPath       : output,
        baselineDirectory: baseline
    ) ? 0 : 1)

case SeatSessionBench.recoveryName:
    let episodes = arguments.count > 2 ? (Int(arguments[2]) ?? 10) : 10
    let output   = argument(3)
    let baseline = argument(4)
    exit(SeatSessionBench.runRecovery(
        episodes         : episodes,
        outputPath       : output,
        baselineDirectory: baseline
    ) ? 0 : 1)

default:
    print("unknown benchmark: \(benchmark)")
    print("available: \(FenceCallbackBench.name), \(FenceClampBench.name), "
        + "\(DisplayLifecycleBench.name), \(SendClickBench.name), "
        + "\(InputTraceOverheadBench.name), "
        + "\(MonitorBench.thirtyName), \(MonitorBench.sixtyName), "
        + "\(MonitorBench.oneHundredTwentyName), \(StageBench.name), "
        + "\(SeatSessionBench.idleName), "
        + "\(SeatSessionBench.recoveryName)")
    exit(2)
}
