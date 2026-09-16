//
//  MonitorBench.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Darwin
import Foundation
import MetalKit
import QuartzCore
import SeatCapture
import Synchronization
import VirtualScreens

/// A window content view that redraws, which is the scene the Monitor is
/// measured against.
///
/// It is the same scene the reference numbers were taken with, and it has to
/// move: ScreenCaptureKit delivers only frames that changed, so a still desktop
/// produces no frames, and a benchmark on a still desktop would measure a
/// stream that is not doing anything.
@MainActor
final class BenchPulseView: NSView {

    var sweep: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let x = (bounds.width + 200) * (0.5 + 0.5 * sin(sweep)) - 100
        NSColor(
            calibratedHue: (sweep / 10).truncatingRemainder(dividingBy: 1),
            saturation   : 0.8,
            brightness   : 1,
            alpha        : 1
        ).setFill()
        NSRect(x: x, y: 0, width: 200, height: bounds.height).fill()
        // A fine text line, so that a pixel mapping that stopped being one to
        // one is visible on screen and not only in the numbers.
        let attributes: [NSAttributedString.Key: Any] = [
            .font           : NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        NSString(string: "AgentSeatKit monitor bench 0123456789 the quick brown fox")
            .draw(at: NSPoint(x: 20, y: bounds.height - 40), withAttributes: attributes)
    }
}

/// A Metal backed producer, which is the only thing in this driver that can
/// really change 120 times a second.
///
/// It exists because of an open question about the 120 level: a `CoreGraphics`
/// redraw on a run loop timer tops out around 60, ScreenCaptureKit sends only
/// frames that changed, and a 120 level measured against a 60 Hz producer would
/// measure 60 and print 120. `MTKView` draws off the display link of the screen
/// the window is on, so on a virtual display created at 120 Hz it produces 120
/// real GPU frames a second, and `completedFrames` says whether it actually
/// did instead of being trusted to.
@MainActor
final class BenchMetalPulseView: MTKView, MTKViewDelegate {

    private let queue    : (any MTLCommandQueue)?
    private let startedAt = CACurrentMediaTime()

    /// `nonisolated` because the GPU's completion handler runs on a driver
    /// thread, and a `Mutex` cannot go into a capture list at all: it is
    /// reached through `self`, which a main actor class is `Sendable` for.
    nonisolated private let counter = Mutex<UInt64>(0)

    /// Frames the GPU reported complete, read from the main actor after the
    /// run: the completion handler fires on a driver thread.
    var completedFrames: UInt64 { counter.withLock { $0 } }

    init(frame: NSRect, framesPerSecond: Int) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        queue = metalDevice?.makeCommandQueue()
        super.init(frame: frame, device: metalDevice)

        delegate                 = self
        preferredFramesPerSecond = framesPerSecond
        colorPixelFormat         = .bgra8Unorm
        isPaused                 = false
        enableSetNeedsDisplay    = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = currentRenderPassDescriptor,
              let drawable   = currentDrawable,
              let buffer     = queue?.makeCommandBuffer()
        else { return }

        // Every frame has to differ from the last one, or the window server
        // coalesces it away before the stream ever sees it.
        let sweep = (sin((CACurrentMediaTime() - startedAt) * 6) + 1) / 2
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            0.05 + 0.90 * sweep,
            0.20 + 0.60 * (1 - sweep),
            0.35 + 0.55 * sweep,
            1
        )
        buffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        buffer.present(drawable)
        buffer.addCompletedHandler { [weak self] finished in
            guard finished.status == .completed else { return }
            self?.counter.withLock { $0 &+= 1 }
        }
        buffer.commit()
    }
}

/// The layer under measurement: it presents the frame the way the kit does and
/// records how long the frame took to get from the capture callback to the
/// screen.
///
/// Wrapping `present` is how the latency of spec section 8 is measured without
/// putting instrumentation on the kit's hot path. The samples array is
/// preallocated, so the measurement itself does not allocate inside the window
/// it is measuring.
nonisolated final class MeasuringMonitorLayer: MonitorLayer, @unchecked Sendable {

    private let samples = Mutex<[UInt64]>([])

    func reserve(_ capacity: Int) {
        samples.withLock { $0.reserveCapacity(capacity) }
    }

    var latencyTicks: [UInt64] { samples.withLock { $0 } }

    override func present(_ frame: SeatFrame) {
        super.present(frame)
        let elapsed = mach_absolute_time() &- frame.receivedAt
        samples.withLock { if $0.count < $0.capacity { $0.append(elapsed) } }
    }
}

/// Holds what the async parts of a run produced, so a synchronous `main` can
/// read it after pumping.
@MainActor
final class BenchOutcome<Value> {
    var result: Result<Value, any Error>?
}

/// MonitorBench measures the live Monitor against the four numbers of spec
/// section 8: net CPU at most 8 % of one core, callback to screen at most 2 ms
/// at p95, at most 12 MB net, at most 1 % of frames coalesced.
///
/// ## The subtracted control
///
/// Every number here is net of a control that is the **same scene without the
/// stream**: the virtual display, the animated window redrawing at 60 Hz, the
/// preview window, the event pump. That control runs first, in the same
/// process, and its CPU and its footprint are what get subtracted. A benchmark
/// without a subtracted control is not a measurement (`CODE_STYLE.md`), and
/// here the control is most of the cost: the scene alone measures 6,8 % of one
/// core and 79 MB.
///
/// Footprint is subtracted as end minus end rather than as a high water mark
/// difference, because a footprint does not come down after a free: the
/// control's own footprint at the moment the stream starts is the floor the
/// stream's cost is counted from.
@MainActor
enum MonitorBench {

    static let thirtyName           = "monitor-30"
    static let sixtyName            = "monitor-60"
    static let oneHundredTwentyName = "monitor-120"

    /// The zero-copy reference row at 1920x1080, the numbers this benchmark has
    /// to stand next to. `CGImage` is the pipeline that was deleted.
    static let reference: [Int: (netCpu: Double, latencyP50Ms: Double, netFootprintMb: Double)] = [
        30: (5.8, 0.485, 3),
        60: (6.2, 0.463, 7),
    ]

    static func name(forFrameRate rate: Int) -> String {
        switch rate {
        case 30 : thirtyName
        case 120: oneHundredTwentyName
        default : sixtyName
        }
    }

    private static func frameRate(_ rate: Int) -> MonitorFrameRate {
        switch rate {
        case 30 : .thirty
        case 120: .oneHundredTwenty
        default : .sixty
        }
    }

    // MARK: The pump

    /// AppKit is pumped for real: a virtual display makes progress only while
    /// `NSApplication` turns its event loop (ADR 0007), the scene's redraw is a
    /// run loop `Timer`, and the kit's presentation is a main queue block the
    /// same loop drains.
    static func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            autoreleasepool {
                if let event = NSApplication.shared.nextEvent(
                    matching: .any,
                    until   : deadline,
                    inMode  : .default,
                    dequeue : true
                ) {
                    NSApplication.shared.sendEvent(event)
                }
            }
        } while Date() < deadline
    }

    static func pump(until condition: () -> Bool, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.002)
        }
        return condition()
    }

    /// Runs one async operation while pumping, and answers what it returned.
    static func awaiting<Value>(
        timeout    : Double = 15,
        _ operation: @escaping @MainActor () async throws -> Value
    ) throws -> Value {

        let outcome = BenchOutcome<Value>()
        Task { @MainActor in
            do    { outcome.result = .success(try await operation()) }
            catch { outcome.result = .failure(error) }
        }
        guard pump(until: { outcome.result != nil }, timeout: timeout),
              let result = outcome.result
        else { throw CaptureFailure.timedOut(.streamStart) }
        return try result.get()
    }

    // MARK: The run

    static func run(
        framesPerSecond  : Int,
        seconds          : Double,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        pump(0.2)

        guard CGPreflightScreenCaptureAccess() else {
            print("\(name(forFrameRate: framesPerSecond)): FAIL, Screen Recording is not granted")
            return false
        }

        let benchmarkName = name(forFrameRate: framesPerSecond)
        let scale         = NSScreen.main?.backingScaleFactor ?? 2
        let viewPoints    = CGSize(width: 960, height: 540)

        do {
            // MARK: the seat: a virtual display attached to the corner
            // The 120 level needs a display that really runs at 120 Hz: it is
            // the precondition `Monitor.start` refuses on, and asking for it
            // here is how that refusal gets exercised rather than assumed.
            let display = try VirtualDisplay.create(VirtualDisplayConfiguration(
                refreshRate: framesPerSecond == 120 ? .high : .standard
            ))
            defer {
                display.invalidate()
                _ = pump(until: { (try? display.isOnline) == false }, timeout: 3)
                _ = try? display.restoreTopology()
                pump(0.5)
            }
            guard pump(until: { display.appKitScreen != nil }, timeout: 5),
                  let virtualScreen = display.appKitScreen
            else {
                print("\(benchmarkName): FAIL, AppKit never published an NSScreen")
                return false
            }
            try display.configureTopology()
            try display.verifyTopology()

            // MARK: the scene the control and the measurement share
            let contentWindow = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800),
                styleMask  : [.titled],
                backing    : .buffered,
                defer      : false,
                screen     : virtualScreen
            )
            contentWindow.title = "AgentSeatKit monitor bench content"
            let contentFrame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let pulse   = framesPerSecond == 120
                ? nil
                : BenchPulseView(frame: contentFrame)
            let metal   = framesPerSecond == 120
                ? BenchMetalPulseView(frame: contentFrame, framesPerSecond: 120)
                : nil
            guard let producer: NSView = pulse ?? metal else {
                print("\(benchmarkName): FAIL, no Metal device to produce 120 Hz content")
                return false
            }
            contentWindow.contentView = producer
            contentWindow.orderFrontRegardless()
            pump(0.2)
            if contentWindow.screen != virtualScreen {
                contentWindow.setFrameOrigin(NSPoint(
                    x: virtualScreen.frame.minX + 200,
                    y: virtualScreen.frame.minY + 200
                ))
                pump(0.2)
            }
            // The CoreGraphics producer needs a timer; the Metal one draws off
            // the screen's own display link and needs nothing.
            let redraw = pulse.map { view in
                Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        view.sweep += 0.02
                        view.needsDisplay = true
                    }
                }
            }
            defer { redraw?.invalidate() }

            // MARK: the preview, on the person's own display
            let previewWindow = NSWindow(
                contentRect: NSRect(x: 60, y: 60, width: viewPoints.width, height: viewPoints.height),
                styleMask  : [.titled],
                backing    : .buffered,
                defer      : false
            )
            previewWindow.title = "AgentSeatKit monitor bench preview"
            let host = NSView(frame: NSRect(origin: .zero, size: viewPoints))
            host.wantsLayer = true
            previewWindow.contentView = host
            let layer = MeasuringMonitorLayer(contentsScale: scale)
            layer.frame = host.bounds
            layer.reserve(Int(seconds) * framesPerSecond * 2 + 1_000)
            host.layer?.addSublayer(layer)
            previewWindow.orderFrontRegardless()
            pump(0.3)

            // MARK: the control: the whole scene, no stream
            print("\(benchmarkName): control, \(Int(seconds)) s of the scene with no stream")
            guard var previous = readUsage(clock: clock) else {
                print("\(benchmarkName): FAIL, proc_pid_rusage refused")
                return false
            }
            let controlStart = previous
            var controlSamples: [Double] = []
            for _ in 0..<Int(seconds) {
                pump(1.0)
                guard let current = readUsage(clock: clock) else { break }
                controlSamples.append(ProcessUsage.cpuPercent(from: previous, to: current, clock: clock))
                previous = current
            }
            guard let controlEnd = readUsage(clock: clock) else {
                print("\(benchmarkName): FAIL, proc_pid_rusage refused")
                return false
            }
            let controlCpu = ProcessUsage.cpuPercent(from: controlStart, to: controlEnd, clock: clock)
            print(String(
                format: "  control: cpu %.2f %%, footprint %.1f MB",
                controlCpu, megabytes(controlEnd.physFootprint)
            ))

            // MARK: the Monitor, at the backing size of the preview
            let monitor = Monitor(displayID: display.displayID, displayGeneration: 1)
            monitor.attach(layer)
            let configuration = MonitorConfiguration(
                targetFrameRate: frameRate(framesPerSecond),
                output         : .backing(pointSize: viewPoints, scale: scale)
            )
            let producedMetalFramesBefore = metal?.completedFrames ?? 0
            try awaiting { try await monitor.start(configuration: configuration) }
            defer { _ = try? awaiting { await monitor.stop() } }

            // Two seconds for the pipeline to reach steady state, outside the
            // window: the first frames pay for the surface pool.
            pump(2.0)

            print(String(
                format: "%@: measurement, %d s at %d fps, %d x %d px",
                benchmarkName, Int(seconds), framesPerSecond,
                Int(configuration.output.pixelSize.width),
                Int(configuration.output.pixelSize.height)
            ))
            guard var measurePrevious = readUsage(clock: clock) else {
                print("\(benchmarkName): FAIL, proc_pid_rusage refused")
                return false
            }
            let measureStart   = measurePrevious
            var measureSamples : [Double] = []
            var appliedRates   : [Double] = []
            var qualityChanges : [String] = []
            var previousApplied = layer.latencyTicks.count

            for second in 0..<Int(seconds) {
                pump(1.0)
                guard let current = readUsage(clock: clock) else { break }
                let cpu = ProcessUsage.cpuPercent(from: measurePrevious, to: current, clock: clock)
                measureSamples.append(cpu)
                let applied = layer.latencyTicks.count
                appliedRates.append(Double(applied - previousApplied))
                previousApplied = applied
                measurePrevious = current

                // The quality loop, driven the way a Seat Host's heartbeat will
                // drive it. The reading handed over is **net of the control**,
                // because that is what the policy's limit is written about: the
                // first run of this benchmark passed the process total and
                // watched the Monitor degrade itself on the cost of the window
                // it was filming.
                let attributable = cpu - controlCpu
                Task { @MainActor in
                    if let change = await monitor.evaluate(attributableCpuPercent: attributable) {
                        qualityChanges.append(
                            "\(change.from.frameRate.rawValue) -> \(change.to.frameRate.rawValue) fps "
                                + "x\(change.to.resolutionScale), \(change.reason)"
                        )
                    }
                }
                if (second + 1) % 10 == 0 {
                    print(String(
                        format: "  %3d s  cpu %.2f %%  applied/s %.0f  coalesced %d  footprint %.1f MB",
                        second + 1, cpu, appliedRates.last ?? 0,
                        monitor.coalescedFrameCount, megabytes(current.physFootprint)
                    ))
                }
            }

            guard let measureEnd = readUsage(clock: clock) else {
                print("\(benchmarkName): FAIL, proc_pid_rusage refused")
                return false
            }
            let measuredCpu = ProcessUsage.cpuPercent(from: measureStart, to: measureEnd, clock: clock)
            let produced    = monitor.producedFrameCount
            let coalesced   = monitor.coalescedFrameCount
            let latency     = Sample(
                name       : benchmarkName,
                nanoseconds: layer.latencyTicks.map { Double($0) * clock.nanosecondsPerTick },
                allocations: 0,
                frees      : 0
            )

            let netCpu          = measuredCpu - controlCpu
            let netFootprint    = Double(measureEnd.physFootprint) - Double(controlEnd.physFootprint)
            let coalescenceRate = produced > 0 ? Double(coalesced) / Double(produced) : 0
            let appliedPerSecond = appliedRates.isEmpty
                ? 0
                : appliedRates.reduce(0, +) / Double(appliedRates.count)

            // MARK: the four gates of spec section 8
            var passed = true
            func gate(_ label: String, _ value: Double, _ limit: Double, _ unit: String) {
                let ok = value <= limit
                print(String(
                    format: "%@ %@: %.3f %@ (budget %.3f)",
                    ok ? "PASS" : "FAIL", label, value, unit, limit
                ))
                passed = passed && ok
            }
            let metalFramesPerSecond = metal.map { view in
                Double(view.completedFrames - producedMetalFramesBefore) / seconds
            }
            print(String(
                format: "%@: cpu %.2f %% measured, %.2f %% control, applied/s %.0f, "
                    + "produced %d, coalesced %d",
                benchmarkName, measuredCpu, controlCpu, appliedPerSecond, produced, coalesced
            ))
            if let metalFramesPerSecond {
                print(String(
                    format: "  producer: %.0f Metal frames a second on a %.0f Hz virtual display",
                    metalFramesPerSecond,
                    CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0
                ))
                // A 120 level measured against a producer that did not reach
                // 120 is the exact mistake worth refusing here, so the
                // producer's own rate is a gate and not a note.
                if framesPerSecond == 120, metalFramesPerSecond < 100 {
                    print(String(
                        format: "FAIL producer rate: %.0f Metal frames a second, under the 100 "
                            + "needed for a 120 level to mean anything",
                        metalFramesPerSecond
                    ))
                    passed = false
                }
            }
            gate("net cpu",       netCpu,                  Budget.monitorNetCpuPercent(atFrameRate: framesPerSecond), "%")
            let latencyLimit = Budget.monitorLatencyNanosecondsP95(atFrameRate: framesPerSecond)
            gate("latency p95",   latency.p95 / 1e6,       latencyLimit / 1e6,                   "ms")
            if framesPerSecond == 120 {
                print(String(
                    format: "  the 120 level's latency budget is its own: spec section 8 gives the "
                        + "row a CPU budget only, and presentation is one main thread hop per frame "
                        + "against a %.1f ms frame interval (p50 %.2f ms, p99 %.2f ms here)",
                    1000.0 / 120.0, latency.p50 / 1e6, latency.p99 / 1e6
                ))
            }
            gate("net footprint", netFootprint / 1_048_576, Budget.monitorNetFootprintBytes / 1_048_576, "MB")
            gate("coalescence",   coalescenceRate,         Budget.monitorCoalescenceRate,        "share")

            if latency.iterations == 0 {
                print("\(benchmarkName): FAIL, no frame ever reached the layer")
                passed = false
            }
            if let row = reference[framesPerSecond] {
                print(String(
                    format: "  zero-copy reference at the same size: cpu %.1f %% net, "
                        + "latency p50 %.3f ms, footprint %.0f MB net "
                        + "(the CGImage pipeline it replaced: 42,2 %%, 2,5 ms, 78 MB)",
                    row.netCpu, row.latencyP50Ms, row.netFootprintMb
                ))
                print(String(
                    format: "  this run: cpu %.2f %% net, latency p50 %.3f ms, footprint %.1f MB net",
                    netCpu, latency.p50 / 1e6, netFootprint / 1_048_576
                ))
            }
            if !qualityChanges.isEmpty {
                print("  quality changed during the run: \(qualityChanges.joined(separator: "; "))")
            }

            var results = latency.json(
                budgetLimit: latencyLimit,
                passed     : latency.p95 <= latencyLimit
            )
            results["frames_per_second_requested"] = framesPerSecond
            results["display_refresh_rate"]        =
                CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0
            if let metalFramesPerSecond {
                results["producer"]                = "Metal, MTKView off the screen's display link"
                results["producer_frames_per_second"] = metalFramesPerSecond
            } else {
                results["producer"]                = "CoreGraphics redraw on a 60 Hz run loop timer"
            }
            results["frames_applied_per_second"]   = appliedPerSecond
            results["frames_produced"]             = produced
            results["frames_coalesced"]            = coalesced
            results["coalescence_rate"]            = coalescenceRate
            results["cpu_percent_measured"]        = measuredCpu
            results["cpu_percent_control"]         = controlCpu
            results["cpu_percent_net"]             = netCpu
            results["cpu_percent_samples"]         = measureSamples
            results["cpu_percent_control_samples"] = controlSamples
            results["footprint_bytes_control"]     = controlEnd.physFootprint
            results["footprint_bytes_measured"]    = measureEnd.physFootprint
            results["footprint_bytes_net"]         = netFootprint
            results["output_pixel_size"]           = [
                Int(configuration.output.pixelSize.width),
                Int(configuration.output.pixelSize.height),
            ]
            results["view_points"]                 = [Int(viewPoints.width), Int(viewPoints.height)]
            results["backing_scale"]               = scale
            results["quality_changes"]             = qualityChanges
            results["quality_final_fps"]           = monitor.quality.frameRate.rawValue
            results["quality_final_scale"]         = monitor.quality.resolutionScale

            let report: [String: Any] = [
                "schema_version": 1,
                "benchmark"     : benchmarkName,
                "provenance"    : provenance(clock: clock),
                "scenario"      : "real virtual display at "
                    + "\(Int(CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0)) Hz, a "
                    + "1200x800 window on it redrawing "
                    + (metal == nil ? "at 60 Hz through CoreGraphics" : "through Metal off the "
                        + "screen's display link") + ", IOSurface into CALayer.contents in a "
                    + "960x540 pt layer-backed view; control is the same scene with no stream, "
                    + "subtracted",
                "results"       : [results],
            ]
            if let outputPath { writeJSON(report, to: outputPath) }
            if let baselineDirectory {
                passed = compareWithBaseline(
                    report,
                    latency        : latency,
                    framesPerSecond: framesPerSecond,
                    directory      : baselineDirectory
                )
                    && passed
            }

            print(passed ? "\(benchmarkName): PASS" : "\(benchmarkName): FAIL")
            return passed
        } catch {
            print("\(benchmarkName): FAIL, \(error)")
            return false
        }
    }

    /// The regression rule on the latency p50, with the same 10 % tolerance and
    /// an absolute floor. p50 and not p95 for the same reason the display
    /// benchmark uses it: the worst of a few hundred main-thread hops is
    /// whatever else the machine was doing. The **budget** above is still gated
    /// on p95, and the floor is one frame interval at the 120 level, where the
    /// hops queue and the p50 moves by a factor of five between runs.
    private static func compareWithBaseline(
        _ report : [String: Any],
        latency  : Sample,
        framesPerSecond: Int,
        directory: String
    ) -> Bool {

        let path = baselinePath(in: directory)
        guard let baseline = readJSON(at: path),
              let rows = baseline["results"] as? [[String: Any]],
              let row  = rows.first(where: { $0["name"] as? String == latency.name }),
              let previous = row["p50"] as? Double, previous > 0
        else {
            mergeIntoBaseline(report, at: path)
            print("\(latency.name): no-baseline, wrote \(path)")
            return true
        }

        let allowed = previous * (1 + Budget.regressionTolerance)
        guard latency.p50 > allowed,
              latency.p50 - previous
                  > Budget.monitorRegressionFloorNanoseconds(atFrameRate: framesPerSecond)
        else {
            mergeIntoBaseline(report, at: path)
            return true
        }
        guard loadAllowsBaselineComparison() else {
            reportInconclusive(
                latency.name,
                measured: String(format: "latency p50 %.3f ms", latency.p50 / 1e6),
                baseline: String(format: "%.3f ms", previous / 1e6)
            )
            mergeIntoBaseline(report, at: path)
            return true
        }
        print(String(
            format: "FAIL %@: latency p50 %.3f ms against a baseline of %.3f ms, over the %.0f %% tolerance",
            latency.name, latency.p50 / 1e6, previous / 1e6, Budget.regressionTolerance * 100
        ))
        return false
    }

}
