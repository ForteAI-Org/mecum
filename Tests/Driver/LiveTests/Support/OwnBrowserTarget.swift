//
//  OwnBrowserTarget.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import WindowPlacement

/// OwnBrowserTarget is a Chromium window this suite **launched itself**, on a
/// profile of its own in a temporary directory.
///
/// It exists next to `ChromeTarget`, which drives the browser the person
/// already has open, and the difference is the point. A contextual menu is a
/// modal tracking loop inside the target: while one is up, that application
/// runs nothing else, and the row that measures it deliberately does not take
/// that risk with a window the person is using. The profile directory means the
/// person's tabs, session and history are neither opened nor read, and the
/// browser this target quits is one it started.
///
/// It is found by process id and never by title alone: with the person's own
/// browser running, two windows answer to the same owner name.
@MainActor
final class OwnBrowserTarget {

    nonisolated static let executablePath =
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    /// A page that is one large text area, because a text area is the control
    /// every Chromium build opens a contextual menu on.
    static let pageHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>ASMENU</title></head>
        <body style="margin:0;background:#123">
        <textarea style="width:100vw;height:100vh;font:14px monospace;background:#012;
        color:#eee;border:0">menu probe</textarea>
        <script>
        const field = document.querySelector("textarea");
        function report() {
            document.title = "ASMENU s=" + (field.selectionEnd - field.selectionStart)
                + " v=" + encodeURIComponent(field.value);
        }
        document.addEventListener("selectionchange", report);
        field.addEventListener("input", report);
        report();
        </script>
        </body></html>
        """

    nonisolated static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    let processID   : pid_t
    let windowNumber: Int

    /// What the window really measures, which is what `stage` has to confirm.
    let expectedSize: CGSize

    private let process : Process
    private let scratch : URL
    private var frame   : CGRect

    private init(process: Process, scratch: URL, window: (pid_t, Int, CGRect)) {
        self.process      = process
        self.scratch      = scratch
        self.processID    = window.0
        self.windowNumber = window.1
        self.frame        = window.2
        self.expectedSize = window.2.size
    }

    /// Launches the browser and waits, pumping, for its window to appear **and
    /// to stop moving**. A window that is still being placed by the browser is
    /// one whose adoption the placement confirmation refuses, correctly.
    static func launched(timeout: Double = 60) throws -> OwnBrowserTarget {

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentseat-menu-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let page = scratch.appendingPathComponent("menu-probe.html")
        try pageHTML.write(to: page, atomically: true, encoding: .utf8)

        let process           = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments     = [
            "--user-data-dir=\(scratch.appendingPathComponent("profile").path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
            "--new-window",
            page.absoluteString,
        ]
        try process.run()

        var found: (pid_t, Int, CGRect)?
        _ = LivePump.run(
            until  : {
                found = window(ofProcess: process.processIdentifier)
                return found != nil
            },
            timeout: timeout
        )
        guard var settled = found else {
            process.terminate()
            throw OwnBrowserFailure.neverAppeared
        }
        var previous = CGRect.null
        _ = LivePump.run(
            until  : {
                guard let now = window(ofProcess: process.processIdentifier) else { return false }
                defer { previous = now.2; settled = now }
                return now.2 == previous
            },
            timeout: 20
        )

        // A window the window server lists is not yet a window the seat can
        // move. The move goes through `AXPosition`, and a browser that has just
        // started answers `AXWindows` with nothing at all for the first
        // moments: adopting inside that gap fails with a window number of zero,
        // which is the accessibility list being empty and not the window being
        // gone.
        let ready = LivePump.run(
            until  : {
                ChromeWindow.element(processID: settled.0, windowNumber: settled.1) != nil
            },
            timeout: 20
        )
        guard ready else {
            process.terminate()
            throw OwnBrowserFailure.neverBecameReadable
        }
        return OwnBrowserTarget(process: process, scratch: scratch, window: settled)
    }

    /// The browser's own window, found by owner process and by size: a Chromium
    /// browser owns several windows of its own besides the one with the page in
    /// it, and the page's is the large one.
    private static func window(ofProcess launched: pid_t) -> (pid_t, Int, CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }

        // The renderer runs in a child process, so the window's owner is the
        // browser process this suite started or one of its descendants, and the
        // owner name plus a launch of our own is what identifies it.
        for entry in entries {
            guard (entry[kCGWindowOwnerName as String] as? String) == "Google Chrome",
                  let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  processID == launched,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  frame.width > 300, frame.height > 300
            else { continue }
            return (processID, number, frame)
        }
        return nil
    }

    var window: WindowReference {
        guard let reference = WindowServerProbe.geometry(of: windowNumber),
              reference.processID == processID
        else {
            return WindowReference(processID: processID, windowNumber: windowNumber, frame: frame)
        }
        return reference.replacingFrame(frame)
    }

    var reference: WindowReference {
        window.replacingFrame(CGRect(origin: frame.origin, size: expectedSize))
    }

    func refresh() {
        guard let geometry = WindowServerProbe.geometry(of: windowNumber) else { return }
        frame = geometry.frame
    }

    /// Well inside the page and below the browser's own chrome, which is where
    /// the text area is.
    func probePoint(within staged: CGRect) -> InputLocation? {
        guard let reference = WindowServerProbe.geometry(of: windowNumber),
              reference.frame == staged,
              let geometry = WindowGeometryProbe.observation(of: reference),
              geometry.window.frame == staged
        else { return nil }
        return InputLocation(
            screenPoint: CGPoint(x: staged.midX, y: staged.minY + staged.height * 0.6),
            observedIn : geometry
        )
    }

    /// Quits the browser this suite started, and only that one.
    func terminate() {
        process.terminate()
        for _ in 0 ..< 40 where process.isRunning { LivePump.run(for: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: scratch)
    }
}

nonisolated enum OwnBrowserFailure: Error, CustomStringConvertible {

    case neverAppeared
    case neverBecameReadable

    var description: String {
        switch self {
        case .neverAppeared:
            "the probe page never appeared among the windows of the browser this suite launched"
        case .neverBecameReadable:
            "the browser this suite launched never exposed its window through accessibility,"
                + " so nothing could move it onto the Virtual Display"
        }
    }
}
