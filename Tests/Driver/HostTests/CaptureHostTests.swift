//
//  CaptureHostTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import ScreenCaptureKit
import SeatCapture
import SeatCore
import Synchronization
import Testing
import VirtualScreens
import WindowPlacement

/// A window content view that redraws, which is the whole reason this suite
/// exists in the Host tier and not in the unit one.
///
/// ScreenCaptureKit delivers only frames that **changed**: on a still desktop
/// every sample carries status `idle`, the kit counts none of them, and a test
/// that asserted "frames arrived" against a static screen would count zero and
/// prove nothing. So the scene produces motion, exactly as the benchmark it
/// shares its numbers with does.
@MainActor
final class PulseView: NSView {

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
    }
}

/// Counts what actually reached a layer's `contents`, which is the end of the
/// zero-copy path and the only place "the person saw a frame" is true.
nonisolated final class CountingMonitorLayer: MonitorLayer, @unchecked Sendable {

    private let count = Atomic<Int>(0)

    var presentedCount: Int { count.load(ordering: .relaxed) }

    override func present(_ frame: SeatFrame) {
        super.present(frame)
        count.wrappingAdd(1, ordering: .relaxed)
    }
}

/// A count a main-actor `Task` can add to while the test is running.
@MainActor
final class Counter {
    var value = 0
}

/// Lets the scene animate **and** the frames reach the main actor, by
/// alternating the only two things this process can do one at a time.
///
/// This is the trap the suite had to be written around, and it is not the trap
/// of ADR 0007. A `@MainActor` test body runs inside a block on the **main
/// dispatch queue**, and a dispatch queue is not reentrant: while
/// `AppKitPump.run` turns a nested run loop, no other main queue block runs, so
/// the kit's `DispatchQueue.main.async` presentation never fires and no `await`
/// ever resumes. Measured here rather than assumed: with a single 3 s pump,
/// ScreenCaptureKit produced frames and not one of them reached a layer, and a
/// plain `DispatchQueue.main.async` posted before the pump ran only after the
/// test body had returned.
///
/// The pump is still needed: the animation is driven by a run loop `Timer` and
/// a virtual display makes progress only while AppKit turns. So the two
/// alternate, a slice of pump for the scene and then a suspension that gives
/// the main queue back so everything waiting on it drains.
///
/// A real application and the benchmark have neither half of this problem: an
/// `NSApplication.run()` and a synchronous `main` both service the main queue
/// from a run loop of their own.
@MainActor
func pumpAndDrain(for seconds: Double, slice: Double = 0.04) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        AppKitPump.run(for: slice)
        try? await Task.sleep(for: .milliseconds(5))
    }
}

extension VirtualDisplaySuites {

    /// The Capture Facility against a real virtual display, a real animated window
    /// on it, and a real stream.
    ///
    /// It leaves the machine as it found it on every path: the display goes away,
    /// its removal is confirmed against the online list, and the person's topology
    /// is restored.
    @Suite("Capture on the running host", .serialized)
    @MainActor
    struct CaptureHostTests {

        @Test("a stream on a virtual display delivers complete frames, and still() returns one",
              .enabled(if: tierEnabled()))
        func streamAndStill() async throws {
            AppKitPump.prepare()
            guard CGPreflightScreenCaptureAccess() else {
                Issue.record("Screen Recording is not granted, the Capture tier cannot run")
                return
            }

            let baselineOnline = Set(try DisplayList.online())
            let display        = try VirtualDisplay.create()
            defer {
                display.invalidate()
                _ = AppKitPump.run(until: { (try? display.isOnline) == false }, timeout: 2)
                _ = try? display.restoreTopology()
                AppKitPump.run(for: 0.3)
            }

            #expect(AppKitPump.run(until: { display.appKitScreen != nil }, timeout: 5))
            let virtualScreen = try #require(display.appKitScreen)
            try display.configureTopology()
            try display.verifyTopology()

            // MARK: the animated scene, on the virtual display
            let contentWindow = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
                styleMask  : [.titled],
                backing    : .buffered,
                defer      : false,
                screen     : virtualScreen
            )
            contentWindow.title = "AgentSeatKit capture host test"
            let pulse = PulseView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            contentWindow.contentView = pulse
            contentWindow.orderFrontRegardless()
            AppKitPump.run(for: 0.2)
            if contentWindow.screen != virtualScreen {
                contentWindow.setFrameOrigin(NSPoint(
                    x: virtualScreen.frame.minX + 200,
                    y: virtualScreen.frame.minY + 200
                ))
                AppKitPump.run(for: 0.2)
            }
            let redraw = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
                MainActor.assumeIsolated {
                    pulse.sweep += 0.02
                    pulse.needsDisplay = true
                }
            }
            defer { redraw.invalidate() }

            // MARK: the Monitor
            let monitor = Monitor(displayID: display.displayID, displayGeneration: 1)
            let layer   = CountingMonitorLayer(contentsScale: 2)
            monitor.attach(layer)

            let streamed = Counter()
            let consumer = Task { @MainActor in
                for await _ in monitor.frames { streamed.value += 1 }
            }
            defer { consumer.cancel() }

            try await monitor.start(configuration: MonitorConfiguration(
                targetFrameRate: .sixty,
                output         : .fixed(CGSize(width: 960, height: 540))
            ))
            await pumpAndDrain(for: 3.0)

            let produced  = monitor.producedFrameCount
            let coalesced = monitor.coalescedFrameCount
            print("""
                capture host: \(produced) complete frames in 3 s, \
                \(coalesced) coalesced, \(layer.presentedCount) presented into a layer, \
                \(streamed.value) yielded to the async stream, quality \
                \(monitor.quality.frameRate.rawValue) fps
                """)
            #expect(produced > 0, "no complete frame from an animated window on the virtual display")
            #expect(layer.presentedCount > 0, "no frame reached the layer's contents")
            #expect(streamed.value > 0, "no frame reached the async stream")
            #expect(monitor.quality == .standard, "the Monitor degraded itself on its own scene")

            // MARK: the Still, and the shape of what a consumer feeds to a model
            //
            // The scene is stopped first. The two capture paths are about to be
            // compared pixel for pixel, and a moving band would put the answer
            // in the noise: with the redraw still running the same comparison
            // reads about 8 %, which says nothing about the format.
            redraw.invalidate()
            await pumpAndDrain(for: 0.4)
            let windowNumber = contentWindow.windowNumber
            let reference = try #require(WindowServerProbe.geometry(of: windowNumber))
            let identity  = try #require(reference.identity)
            let still = try await SeatCaptureStream.still(of: .attestedWindow(identity))
            print("capture host: still \(Int(still.pixelSize.width))x\(Int(still.pixelSize.height)) px")
            #expect(still.pixelSize.width  > 0)
            #expect(still.pixelSize.height > 0)
            #expect(still.source == .window(identity))
            #expect(still.geometry.source == still.source)
            #expect(still.geometry.capturesFullWindow)
            #expect(still.geometry.windowObservation?.window.identity == identity)

            let stillImage = try #require(still.makeCGImage(), "a Still with no readable pixels")
            #expect(stillImage.width  == Int(still.pixelSize.width))
            #expect(stillImage.height == Int(still.pixelSize.height))

            // A consumer that wants pixels can also build this image with
            // `SCScreenshotManager.captureImage` on the same filter. Both are taken
            // here in the same run, because "the screenshot the model sees did not
            // change shape" is a claim that needs the two side by side and not an
            // argument about which API reads better.
            let legacy = try await Self.legacyCaptureImage(windowNumber: windowNumber)
            print("capture host: legacy captureImage \(legacy.width)x\(legacy.height) px")
            #expect(legacy.width  == stillImage.width)
            #expect(legacy.height == stillImage.height)

            let difference = try #require(
                FrameDifference.meanPixelDifference(legacy, stillImage),
                "the two captures cannot be compared, which a before and after diff needs"
            )
            print(String(
                format: "capture host: still against legacy, mean pixel difference %.4f %% "
                    + "(scene stopped)",
                difference * 100
            ))
            // Same window, same size, same still scene, one path through
            // `SCScreenshotManager.captureImage` and one through
            // `captureSampleBuffer` plus `SeatFrame.makeCGImage`. Anything more
            // than rounding here means the picture changed: a flipped image, a
            // swapped channel order, a different colour space.
            #expect(difference < 0.01)

            await monitor.stop()
            contentWindow.orderOut(nil)
            AppKitPump.run(for: 0.3)
            #expect(Set(try DisplayList.online()) == baselineOnline.union([display.displayID]))
        }

        @Test("the 120 level is refused on a display that does not run at 120 Hz",
              .enabled(if: tierEnabled()))
        func oneHundredTwentyNeedsTheDisplay() async throws {
            AppKitPump.prepare()

            // A 60 Hz virtual display: asking for 120 has to fail with a name, not
            // deliver 60 frames a second and let the caller call them 120.
            let display = try VirtualDisplay.create(
                VirtualDisplayConfiguration(refreshRate: .standard)
            )
            defer {
                display.invalidate()
                _ = AppKitPump.run(until: { (try? display.isOnline) == false }, timeout: 2)
                _ = try? display.restoreTopology()
                AppKitPump.run(for: 0.3)
            }
            #expect(AppKitPump.run(until: { display.appKitScreen != nil }, timeout: 5))
            try display.configureTopology()

            let monitor = Monitor(displayID: display.displayID)
            let refresh = CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0
            print("capture host: virtual display reports \(refresh) Hz")

            await #expect(throws: CaptureFailure.frameRateUnsupported(
                requested         : 120,
                displayRefreshRate: refresh
            )) {
                try await monitor.start(configuration: MonitorConfiguration(
                    targetFrameRate: .oneHundredTwenty,
                    output         : .fixed(CGSize(width: 640, height: 360))
                ))
            }
        }

        /// The path a consumer takes without `still()`: a `CGImage` straight from
        /// `SCScreenshotManager`, at the window's frame times the filter's scale,
        /// with the same two single-window flags.
        static func legacyCaptureImage(windowNumber: Int) async throws -> CGImage {
            let content = try await shareableContent()
            guard let window = content.windows.first(where: { Int($0.windowID) == windowNumber })
            else { throw CaptureFailure.windowNotShareable(windowNumber: windowNumber) }

            let filter        = SCContentFilter(desktopIndependentWindow: window)
            let scale         = max(1, CGFloat(filter.pointPixelScale))
            let configuration = SCStreamConfiguration()
            configuration.width                        = Int((window.frame.width  * scale).rounded())
            configuration.height                       = Int((window.frame.height * scale).rounded())
            configuration.showsCursor                  = false
            configuration.capturesAudio                = false
            configuration.ignoreShadowsSingleWindow    = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.captureResolution            = .best
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        }
    }
}
