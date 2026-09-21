import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Result of a live capture — purely `Sendable` data, so it can cross back to any actor.
public struct CapturedWindow: Sendable {
    public let image: CGImage          // CGImage is Sendable on this SDK
    public let title: String?
    public let frameGlobalPt: CGRect

    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// A window resolved purely from pixels (no AX) by the point under the cursor — for zero-AX apps (Premiere,
/// some Adobe/Electron) whose content panels expose no Accessibility element. Sendable.
public struct PointWindow: Sendable {
    public let captured: CapturedWindow
    public let bundleID: String
}

/// High-level live capture: enumerate → correlate → capture, executed entirely within a single
/// **nonisolated async domain** so the non-`Sendable` `SCWindow` never crosses an actor boundary.
/// Callers (even `@MainActor`) pass only `Sendable` criteria and receive a `Sendable` ``CapturedWindow``.
public struct WindowCaptureService: Sendable {
    private let capture: any WindowCapture

    /// Has this process EVER captured or enumerated successfully? A single success proves Screen Recording
    /// is granted, so nothing afterwards may blame it. Written because a "no scene" message that offered
    /// "…and is Screen Recording granted?" as an alternative cause sent an agent — and its user — off to
    /// System Settings, while the truth was that the frontmost app (a menu-bar downloader) simply had no
    /// window. Offering a plausible wrong cause is the same defect as asserting one.
    public enum CaptureFacts {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var succeeded = false
        public static func noteSuccess() {
            lock.lock(); succeeded = true; lock.unlock()
        }
        /// True once anything has been captured or enumerated in this process.
        public static var everSucceeded: Bool {
            lock.lock(); defer { lock.unlock() }; return succeeded
        }
    }

    public init(capture: any WindowCapture = ScreenshotManagerCapture()) {
        self.capture = capture
    }

    /// Whether Screen Recording is authorized — probes by attempting window enumeration (the first
    /// attempt also triggers the TCC prompt). Returns a `Sendable` `Bool`, so it's safe to call from
    /// any actor (the non-`Sendable` window list never leaves this nonisolated method).
    public func screenRecordingAuthorized() async -> Bool {
        do { _ = try await WindowEnumerator.windows(); CaptureFacts.noteSuccess(); return true }
        catch { return false }
    }

    /// Find the window matching the given AX criteria and capture it at native scale. Returns `nil` if no
    /// plausible window correlates OR enumeration/capture fails. Each attempt is bounded by `timeout`: the
    /// SCK one-shot intermittently leaks its continuation and hangs, so a timed-out attempt is ABANDONED and
    /// retried (it succeeds on retry in practice) rather than hanging the caller forever.
    public func captureMatchingWindow(
        bundleID: String,
        title: String?,
        axWindowFrameGlobalPt: CGRect,
        minIoU: Double = 0.5,
        timeout: Double = 4.0,
        attempts: Int = 2
    ) async throws -> CapturedWindow? {
        guard CaptureGate.circuit.allow() else { return nil }   // breaker open: don't spawn a capture (no leak)
        let (window, responded): (CapturedWindow?, Bool) = await CaptureGate.serialized {   // cross-process: concurrent SCK one-shots starve each other
            for attempt in 1...max(1, attempts) {
                let outcome = await raceTimeout(timeout) { () -> CaptureOutcome in
                    do {
                        return .ok(try await self.captureOnce(bundleID: bundleID, title: title,
                                                              axWindowFrameGlobalPt: axWindowFrameGlobalPt, minIoU: minIoU))
                    } catch { return .failed }
                }
                switch outcome ?? .timedOut {
                case .ok(let window):
                    // SCK RESPONDED (correlated + captured, or honestly no window) — either way the
                    // enumeration behind it succeeded, which is proof the grant exists.
                    CaptureFacts.noteSuccess()
                    return (window, true)
                case .failed: return (nil, false)            // enumerate/capture threw (e.g. not granted)
                case .timedOut:
                    if ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil {
                        FileHandle.standardError.write(Data("[capture] attempt \(attempt) timed out after \(timeout)s — retrying\n".utf8))
                    }
                    continue                                 // hung SCK call → abandon this attempt, retry
                }
            }
            return (nil, false)                              // all attempts hung
        }
        CaptureGate.circuit.record(success: responded)
        return window
    }

    /// Capture the frontmost normal on-screen window CONTAINING `point`, identified with NO Accessibility —
    /// the AX-free capture path for apps that expose no AX element under the cursor. Same timeout/retry as
    /// `captureMatchingWindow` (the SCK one-shot can hang). Returns nil if no such window / capture fails.
    public func captureWindow(underPoint point: CGPoint, preferringPID: pid_t? = nil,
                              timeout: Double = 4.0, attempts: Int = 2) async throws -> PointWindow? {
        guard CaptureGate.circuit.allow() else { return nil }
        let (pw, responded): (PointWindow?, Bool) = await CaptureGate.serialized {
            for attempt in 1...max(1, attempts) {
                let outcome = await raceTimeout(timeout) { () -> PointOutcome in
                    do { return .ok(try await self.captureWindowOnce(underPoint: point, preferringPID: preferringPID)) } catch { return .failed }
                }
                switch outcome ?? .timedOut {
                case .ok(let pw): return (pw, true)
                case .failed: return (nil, false)
                case .timedOut:
                    if ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil {
                        FileHandle.standardError.write(Data("[capture] under-point attempt \(attempt) timed out — retrying\n".utf8))
                    }
                    continue
                }
            }
            return (nil, false)
        }
        CaptureGate.circuit.record(success: responded)
        return pw
    }

    /// Capture an app's OPEN POP-UP window (dropdown list, context menu) at native scale, correlated
    /// by its CGWindowList frame — pop-ups have no title, so frame+pid IS their identity. This is the
    /// vision-first pop-up eye: capturing the pop-up ITSELF (not the main window it floats over) is
    /// what makes its items readable — Premiere's format list OCR'd as garble only because the list
    /// was a 300px sliver inside a 3000px main-window capture.
    public func capturePopupWindow(pid: pid_t, frameGlobalPt: CGRect,
                                   timeout: Double = 4.0) async throws -> CapturedWindow? {
        guard CaptureGate.circuit.allow() else { return nil }
        let (window, responded): (CapturedWindow?, Bool) = await CaptureGate.serialized {
            let outcome = await raceTimeout(timeout) { () -> CaptureOutcome in
                do {
                    // SCREEN REGION, not window capture: a GPU pop-up's CGWindow can be a proxy whose
                    // window-capture returns the PARENT's content (measured on Premiere — main window
                    // squeezed into the popup's frame). The display region is compositor truth, and a
                    // topmost pop-up is exactly what those pixels show.
                    guard let img = try await ScreenshotManagerCapture().captureRegion(rectGlobalPt: frameGlobalPt)
                    else { return .ok(nil) }
                    return .ok(CapturedWindow(image: img, title: nil, frameGlobalPt: frameGlobalPt))
                } catch { return .failed }
            }
            switch outcome ?? .timedOut {
            case .ok(let w): return (w, true)
            case .failed, .timedOut: return (nil, false)
            }
        }
        CaptureGate.circuit.record(success: responded)
        return window
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0 else { return 0 }
        let ia = inter.width * inter.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ua > 0 ? Double(ia / ua) : 0
    }

    /// A lightweight window probe under a global (top-left) point using ONLY CGWindowList — NO
    /// ScreenCaptureKit capture, so it's cheap enough to run on every hover. The ambient watcher uses it to
    /// detect when the cursor has entered a NEW window/state (→ re-capture+OCR) vs is still in a cached one
    /// (→ free lookup). Restricted to the frontmost app (`preferringPID`); returns its title + frame.
    public struct WindowProbe: Sendable {
        public let title: String?
        public let frameGlobalPt: CGRect
        public init(title: String?, frameGlobalPt: CGRect) { self.title = title; self.frameGlobalPt = frameGlobalPt }
    }

    public func windowInfoUnderPoint(_ point: CGPoint, preferringPID: pid_t?) -> WindowProbe? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for cg in info {
            if let preferringPID, (cg[kCGWindowOwnerPID as String] as? pid_t) != preferringPID { continue }
            // Floating layers included (see isWindowLayer): a click lands on the modal in front, not
            // on the document window behind it.
            guard let l = cg[kCGWindowLayer as String] as? Int, Self.isWindowLayer(l),
                  let boundsDict = cg[kCGWindowBounds as String] as? [String: Any] else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect), rect.contains(point) else { continue }
            return WindowProbe(title: cg[kCGWindowName as String] as? String, frameGlobalPt: rect)
        }
        return nil
    }

    /// The app's KEY window (the one the user is looking at) via CGWindowList — no cursor needed. Used by
    /// `scene`/`describe_scene`/`act` to perceive+act on the right window.
    ///
    /// CGWindowList is FRONT-TO-BACK z-order, so we prefer the FRONTMOST substantial window: a modal
    /// dialog (Premiere's "AAF Export Settings", a confirm sheet) sits ABOVE the main window and must win —
    /// the agent has to see/act on the dialog that's actually up, not the big window behind it (measured:
    /// the AAF dialog + Slack delete confirm were invisible because we picked the LARGEST window). With no
    /// dialog, the main window is frontmost. Tiny HUDs/tooltips are skipped; if nothing clears that bar we
    /// fall back to the largest (old behavior), so normal perception never regresses.
    ///
    /// "Substantial" is judged by AREA, not by both sides clearing a minimum. A `height >= 140` rule looks
    /// reasonable and silently loses SHORT WIDE DIALOGS: Pro Tools' "New Tracks" is 815×124, so the engine
    /// skipped the modal it was supposed to drive and captured the edit window behind it — the agent then
    /// hunted for a dialog that was right there, while `run_menu` reported the menu item disabled *because*
    /// that dialog was open (measured). A tooltip is small in BOTH dimensions and small in area; a dialog
    /// is not.
    /// An OPEN POPUP MENU wins outright: while it is up it IS the interaction surface, the same way a
    /// modal dialog beats the window behind it (measured: Pro Tools' track-type dropdown is 129×197 on
    /// LAYER 101 — the agent clicked it, saw nothing, and spent the rest of the session typing guesses
    /// at a menu it couldn't read). Which windows count as pop-ups, and this choice, are now ONE
    /// decision in ``WindowSurfaceClassifier`` — see ``surfaces(pid:)`` for why that matters.
    public func frontmostWindowFrame(pid: pid_t) -> WindowProbe? {
        surfaces(pid: pid).interaction
    }

    /// Every on-screen window this app owns, FRONT-TO-BACK — the one enumeration both the window
    /// choice and the pop-up detection are decided from.
    public func windowRows(pid: pid_t) -> [WindowRow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var rows: [WindowRow] = []
        for cg in info {   // front-to-back
            guard (cg[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let layer = cg[kCGWindowLayer as String] as? Int,
                  let boundsDict = cg[kCGWindowBounds as String] as? [String: Any] else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect) else { continue }
            rows.append(WindowRow(layer: layer, frameGlobalPt: rect,
                                  title: cg[kCGWindowName as String] as? String,
                                  number: (cg[kCGWindowNumber as String] as? Int) ?? 0))
        }
        return rows
    }

    /// WHAT IS ON THIS APP'S SCREEN, classified once: which windows are open pop-ups, and which single
    /// window we perceive and click. Ticket 12: the two used to be separate walks with separate gates,
    /// so DaVinci's resolution list (a dropdown drawn as an ORDINARY window) was captured as the scene
    /// AND reported as "no pop-up open" — the scene held the list's pixels while every pop-up path sat
    /// behind a gate that said there was no pop-up. `LOCATOR_NO_WINDOW_LAYER_POPUPS` turns the
    /// window-layer half of the rule off, leaving menu-layer detection exactly as it was.
    public func surfaces(pid: pid_t) -> WindowSurfaces {
        WindowSurfaceClassifier.classify(
            windowRows(pid: pid),
            allowFloatingLists: ProcessInfo.processInfo.environment["LOCATOR_NO_WINDOW_LAYER_POPUPS"] == nil)
    }

    /// Does this app have a pop-up menu OPEN right now? Callers must not "focus the app" before
    /// clicking into one: an activation event CANCELS macOS menu tracking, so the menu vanishes and the
    /// click lands on whatever was behind it (measured on Pro Tools — every attempt to pick "Routing
    /// Folder" closed the menu and left the type unchanged; the identical click without activating
    /// selected it first try).
    public func hasOpenPopup(pid: pid_t) -> Bool { !openPopupFrames(pid: pid).isEmpty }

    /// The frames (top-left global points) of every open pop-up window this app owns. Used to decide
    /// whether a target is INSIDE the popup (keyboard type-ahead applies) or behind it (a supervised
    /// gemini session typed junk into an open menu because EVERY act took the type-ahead branch), and
    /// whether a SUBMENU opened (popup count grows).
    public func openPopupFrames(pid: pid_t) -> [CGRect] { surfaces(pid: pid).popups }

    /// Layers where an app parks an OPEN POP-UP MENU (a dropdown's list, a context menu). Not "chrome":
    /// while one is open it is the only thing the user can interact with, so perception must read it.
    /// Bounded well below the cursor/screensaver layers (500+).
    ///
    /// NOT the only way a pop-up is recognised: a toolkit that draws its own widgets (Qt, in DaVinci
    /// Resolve) parks a combo's list on an ORDINARY window layer, where no layer number can identify
    /// it — see `WindowSurfaceClassifier.floatingList`.
    public static func isPopupLayer(_ layer: Int) -> Bool { (21...200).contains(layer) }

    /// Window layers we're willing to DRIVE. Not just 0: pro apps put modals and palettes on the
    /// FLOATING layers, and a `layer == 0` filter makes them invisible to perception entirely.
    /// Measured on Pro Tools: "New Tracks" sits on layer 0 while focused and moves to LAYER 8 when
    /// focus shifts — same dialog, same pixels, and the agent could only see it half the time.
    /// Excluded above 20: status items (~25), pop-up menus (~101), tooltips/cursors/screensaver (500+)
    /// are chrome we must never mistake for the window the user is working in.
    public static func isWindowLayer(_ layer: Int) -> Bool { (0...20).contains(layer) }

    /// Big enough to be a window the user is meant to interact with, rather than a tooltip, a badge or a
    /// drag shadow. Pure geometry (no AX) so it holds for the zero-AX apps too. Pinned by tests.
    public static func isSubstantialWindow(_ r: CGRect) -> Bool {
        r.width >= 200 && r.height >= 90 && (r.width * r.height) >= 40_000
    }

    /// A captured screen REGION (all on-screen content composited in that rect) + its global TOP-LEFT frame.
    public struct RegionShot: Sendable {
        public let image: CGImage
        public let regionGlobalPt: CGRect   // the captured rect in global TOP-LEFT points
    }

    /// Capture a screen REGION around a global TOP-LEFT point — the cursor-companion overlay's primitive.
    /// Composites whatever is on screen there (any app's window, the desktop) so it needs only Screen
    /// Recording for THIS process, independent of any per-app allowlist. Bounded by the same timeout/retry
    /// as window capture (the SCK one-shot can hang). Runs OFF the main actor (nonisolated async).
    public func captureRegion(aroundGlobalPoint center: CGPoint, size: CGFloat,
                              timeout: Double = 3.0, attempts: Int = 2) async throws -> RegionShot? {
        let half = size / 2
        return try await captureRegion(rect: CGRect(x: center.x - half, y: center.y - half, width: size, height: size),
                                       timeout: timeout, attempts: attempts)
    }

    /// Capture an explicit global TOP-LEFT rect (e.g. a cursor square already CLIPPED to an app's window),
    /// so the companion sees only that window's pixels, not the whole screen under the square.
    public func captureRegion(rect: CGRect, timeout: Double = 3.0, attempts: Int = 2) async throws -> RegionShot? {
        guard CaptureGate.circuit.allow() else { return nil }
        let (shot, responded): (RegionShot?, Bool) = await CaptureGate.serialized {
            for _ in 1...max(1, attempts) {
                let outcome = await raceTimeout(timeout) { () -> RegionOutcome in
                    do { return .ok(try await self.captureRegionOnce(rect: rect)) } catch { return .failed }
                }
                switch outcome ?? .timedOut {
                case .ok(let shot): return (shot, true)
                case .failed: return (nil, false)
                case .timedOut: continue
                }
            }
            return (nil, false)
        }
        CaptureGate.circuit.record(success: responded)
        return shot
    }

    private enum RegionOutcome: Sendable { case ok(RegionShot?); case failed; case timedOut }

    private func captureRegionOnce(rect requested: CGRect) async throws -> RegionShot? {
        // Resolve the display under the rect's center via CoreGraphics (CGDisplayBounds is reliably global
        // TOP-LEFT, matching CGEvent's cursor coords) and match it to its SCDisplay by displayID.
        let center = CGPoint(x: requested.midX, y: requested.midY)
        var dispID = CGMainDisplayID()
        var matched: UInt32 = 0
        CGGetDisplaysWithPoint(center, 1, &dispID, &matched)
        let bounds = CGDisplayBounds(dispID)
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == dispID }) ?? content.displays.first else { return nil }

        let region = requested.integral.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }

        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: region.minX - bounds.minX, y: region.minY - bounds.minY, width: region.width, height: region.height)
        config.width = Int(region.width * 2)    // capture at ~Retina; drawing derives scale from image/region
        config.height = Int(region.height * 2)
        config.showsCursor = false
        // Peek's colored overlay is instrumentation, not app content. In interval mode it can
        // still be painted when the next capture starts; feeding it back creates phantom edges.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return RegionShot(image: image, regionGlobalPt: region)
    }

    private enum PointOutcome: Sendable { case ok(PointWindow?); case failed; case timedOut }

    private func captureWindowOnce(underPoint point: CGPoint, preferringPID: pid_t?) async throws -> PointWindow? {
        let windows = try await WindowEnumerator.windows()
        let byID = Dictionary(windows.compactMap { w in w.owningApplication?.bundleIdentifier != nil ? (w.windowID, w) : nil },
                              uniquingKeysWith: { a, _ in a })

        // TRUE z-order via CGWindowList (front-to-back, unlike SCShareableContent): the TOPMOST capturable
        // app window CONTAINING the point is what the user sees and points at — a modal dialog drawn over
        // the much larger main window (Premiere's AAF Export Settings), not the main window behind it.
        // Matching to an SCWindow filters out system overlays (menu bar/cursor) automatically.
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for cg in info {
                guard let num = cg[kCGWindowNumber as String] as? Int, let window = byID[CGWindowID(num)],
                      let bounds = cg[kCGWindowBounds as String] as? [String: Any],
                      let bundleID = window.owningApplication?.bundleIdentifier else { continue }
                // Restrict to the FRONTMOST app — system UI (Dock/menu bar/Stage Manager) and other apps sit
                // ABOVE normal windows in z-order and own large windows that overlap the point; without this
                // the topmost-at-point is the Dock, not the dialog the user is in.
                if let preferringPID, window.owningApplication?.processID != preferringPID { continue }
                var rect = CGRect.zero
                guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect), rect.contains(point) else { continue }
                let image = try await capture.capture(window: window)
                return PointWindow(captured: CapturedWindow(image: image, title: window.title, frameGlobalPt: window.frame), bundleID: bundleID)
            }
        }

        // Fallback (CGWindowList unavailable): prefer the FRONTMOST app's containing window, else the first.
        let candidates = windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.contains(point) && $0.owningApplication?.bundleIdentifier != nil
        }
        guard let window = candidates.first(where: { $0.owningApplication?.processID == preferringPID }) ?? candidates.first,
              let bundleID = window.owningApplication?.bundleIdentifier else { return nil }
        let image = try await capture.capture(window: window)
        return PointWindow(captured: CapturedWindow(image: image, title: window.title, frameGlobalPt: window.frame), bundleID: bundleID)
    }

    private enum CaptureOutcome: Sendable { case ok(CapturedWindow?); case failed; case timedOut }

    private func captureOnce(bundleID: String, title: String?, axWindowFrameGlobalPt: CGRect, minIoU: Double) async throws -> CapturedWindow? {
        let windows = try await WindowEnumerator.windows()
        guard let window = WindowCorrelator.correlate(
            axWindowFrameGlobalPt: axWindowFrameGlobalPt, bundleID: bundleID, title: title, among: windows, minIoU: minIoU
        ) else { return nil }
        let image = try await capture.capture(window: window)
        return CapturedWindow(image: image, title: window.title, frameGlobalPt: window.frame)
    }
}
