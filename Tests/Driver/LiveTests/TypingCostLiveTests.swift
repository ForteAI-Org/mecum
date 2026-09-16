//
//  TypingCostLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore
import SeatInput
import Testing
import WindowPlacement

/// PreparedTextPlatform is a platform that prepares a typed string, which the
/// two shipped ones do not, so a sweep can price the Preparation instead of
/// arguing about it. `AGENTSEAT_TYPING_PREPARE=1` turns it on.
///
/// Whether a typed string needs it was the open question this was written for,
/// and it has since been answered next door, in four window states on both
/// families: it does not. What does is the whole string on one key event, which
/// is a Command of its own now and carries its own policy.
nonisolated struct PreparedTextPlatform: InputPlatform {

    let base: any InputPlatform

    var prepareText = ProcessInfo.processInfo.environment["AGENTSEAT_TYPING_PREPARE"] == "1"

    func preparation(for command: InputCommand) -> Preparation {
        if prepareText, case .text = command { return .internalAppKitState }
        if prepareText, case .key  = command { return .internalAppKitState }
        return base.preparation(for: command)
    }

    func preparationSettle(for command: InputCommand) -> Duration {
        base.preparationSettle(for: command)
    }

    var dragPacing: DragPacing { base.dragPacing }
}

/// Whether the typing sweep runs. It is off in the acceptance run: one pass
/// types hundreds of thousands of characters into two applications and takes
/// minutes, which is a calibration and not a gate.
nonisolated func typingSweepSkipReason() -> String? {
    liveSkipReason(
        optIn       : "AGENTSEAT_TYPING_SWEEP",
        needsFixture: true,
        needsChrome : true
    )
}

/// A comma separated list of numbers from the environment, or the default.
nonisolated func sweepNumbers(_ name: String, _ fallback: [Int]) -> [Int] {
    guard let raw = ProcessInfo.processInfo.environment[name], !raw.isEmpty else { return fallback }
    return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
}

/// How long the person's hand has been off the machine. The kit's events are
/// posted to one process and never enter the HID stream, so this reads the
/// person and nobody else; a run it sees during is inconclusive, not a pass.
nonisolated func secondsSinceHand() -> Double {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
    return types
        .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
        .min() ?? .infinity
}

/// One target the sweep types into: how to reach it, how to empty it, and how
/// much of the string it says has arrived.
@MainActor
protocol TypingTarget: AnyObject {

    var name    : String { get }
    var platform: any InputPlatform { get }
    var window  : WindowReference { get }

    /// Brings the target back to an empty editor and answers whether it is
    /// ready. Everything before a run is paid for before the clock starts.
    func reset() -> Bool

    /// What the target itself says has arrived. This is the only reading the
    /// sweep trusts: a receipt says what was posted, not what landed.
    func arrivedCount() -> Int

    /// Whether that count is characters rather than edits. A target that counts
    /// edits answers 1 for a whole string inserted at once, which is the right
    /// answer to a different question.
    var countsCharacters: Bool { get }

    /// Everything else the target knows, for the line under a short run.
    func diagnostics() -> String

    func terminate()

    /// The process the events are posted to, for the checks that ask which
    /// application is in front.
    var processID: pid_t { get }

    /// How many characters the target's own editor has taken since it started.
    /// It never goes backwards, which a field's length does the moment anything
    /// empties it, so a grid whose cells are seconds apart can subtract two
    /// readings and get an answer about one cell.
    func charactersTaken() -> Int

    /// How many edits the target's own editor has applied since it started. One
    /// per character typed, and **one** for a whole string inserted at once:
    /// the difference between the two is the whole point of the comparison.
    func editsApplied() -> Int
}

/// The AppKit half: the consumer's instrumented target, relaunched for every
/// run.
///
/// It is relaunched rather than emptied because the alternative is a confound,
/// and the confound is the finding: a single line text control that already
/// holds thousands of characters takes longer per character than an empty one,
/// so a grid that reuses one process measures its own history.
@MainActor
final class FixtureTypingTarget: TypingTarget {

    let name = "AppKit"
    let platform: any InputPlatform = AppKitPlatform()

    private var fixture: FixtureTarget?

    var window: WindowReference {
        fixture?.window ?? WindowReference(processID: 0, windowNumber: 0, frame: .zero)
    }

    func reset() -> Bool {
        fixture?.terminate()
        fixture = try? FixtureTarget.launched()
        // The target puts the caret in its own field on a later turn of its run
        // loop, so a run that starts the instant the window appears types into
        // nothing.
        LivePump.run(for: 0.6)
        return fixture != nil
    }

    /// The target's own change counter, and deliberately not the length of the
    /// string it publishes: a framework text control answers with a value that
    /// lags behind what its field editor has already applied, and the counter
    /// does not.
    func arrivedCount() -> Int {
        guard let fixture else { return 0 }
        fixture.refresh()
        return fixture.latest.textChangeCount
    }

    let countsCharacters = false

    var processID: pid_t { fixture?.latest.processID ?? 0 }

    /// The field's own length. Nothing empties this target's field, so the
    /// length is monotone here and the second reading of a pair is honest.
    func charactersTaken() -> Int {
        guard let fixture else { return 0 }
        fixture.refresh()
        return fixture.latest.textValue.count
    }

    func editsApplied() -> Int { arrivedCount() }

    func diagnostics() -> String {
        guard let fixture else { return "not launched" }
        return "changes \(fixture.latest.textChangeCount), field \(fixture.latest.textValue.count) "
            + "characters, active \(fixture.latest.applicationIsActive), "
            + "key window \(fixture.latest.windowIsKey)"
    }

    func terminate() {
        fixture?.terminate()
        fixture = nil
    }
}

/// The Chromium half: a browser **this suite launches**, with its own profile
/// directory and its own page, so nothing here touches the person's browser,
/// their tabs, their profile or their clipboard.
///
/// The page reports the length of its own field in its window title, which is
/// the one channel another process can read without asking the browser for
/// anything, and it empties itself after a second and a half of silence, which
/// is what lets a run start from zero without driving the browser's interface.
@MainActor
final class ChromiumTypingTarget: TypingTarget {

    nonisolated static let binaryPath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    static let titleMark  = "ASTYPE"

    nonisolated static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    /// `n` is the field's own length, `k` the keystrokes the field saw and `d`
    /// the ones the document saw. The title is rewritten at most every 15 ms so
    /// that reading the text does not become the cost being measured.
    ///
    /// `tc`, `te` and `td` are the same readings without the emptying:
    /// characters taken, edits applied and key downs the **document** saw since
    /// the page loaded, none of them reset when the field clears itself. A grid
    /// whose cells are seconds apart needs a counter that survives the emptying,
    /// or every cell measures the timer. `td` and `tk` are the pair that
    /// separates the three ways a cell can come up empty: an event that never
    /// reached the renderer moves neither, one that reached the page but not the
    /// field moves `td` alone, and one the field itself refused moves both.
    private static let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <title>ASTYPE n=0 k=0 d=0 tc=0 te=0 td=0 tk=0</title></head>
        <body style="margin:0;background:#123">
        <textarea id="t" style="position:fixed;inset:0;border:0;font:13px monospace"></textarea>
        <script>
        let k = 0, d = 0, tc = 0, te = 0, td = 0, tk = 0, seen = 0, lastTitle = 0, lastKey = 0;
        const u = () => {
          lastTitle = performance.now();
          document.title = 'ASTYPE n=' + t.value.length + ' k=' + k + ' d=' + d
            + ' tc=' + tc + ' te=' + te + ' td=' + td + ' tk=' + tk;
        };
        document.addEventListener('keydown', () => { d++; td++; lastKey = performance.now(); }, true);
        t.addEventListener('keydown', () => { k++; tk++; lastKey = performance.now(); });
        t.addEventListener('input', () => {
          const length = t.value.length;
          if (length > seen) { tc += length - seen; }
          seen = length;
          te++;
          if (performance.now() - lastTitle > 15) u();
        });
        setInterval(u, 50);
        setInterval(() => {
          if ((k > 0 || d > 0 || t.value.length > 0) && performance.now() - lastKey > 1500) {
            t.value = ''; k = 0; d = 0; seen = 0; t.focus(); u();
          }
        }, 200);
        t.focus(); u();
        </script></body></html>
        """

    let name = "Chromium"
    let platform: any InputPlatform = ChromiumPlatform()

    private let process     : Process
    private let profile     : URL
    let processID           : pid_t
    private let windowNumber: Int
    private var frame       : CGRect

    var window: WindowReference {
        guard let reference = WindowServerProbe.geometry(of: windowNumber),
              reference.processID == processID
        else {
            return WindowReference(processID: processID, windowNumber: windowNumber, frame: frame)
        }
        return reference.replacingFrame(frame)
    }

    /// Launches the browser on its own profile and waits for the page's own
    /// window, matched by the process this suite started and by nothing else.
    static func launched(timeout: Double = 30) throws -> ChromiumTypingTarget {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentseat-typing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let pageURL = profile.appendingPathComponent("page.html")
        try page.write(to: pageURL, atomically: true, encoding: .utf8)

        let process           = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments     = [
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-component-update",
            "--disable-background-networking",
            // A renderer whose window is not in front throttles its own timers,
            // which would be measured as the target falling behind. The events
            // are not throttled, the reading of them is.
            "--disable-background-timer-throttling",
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
            "--window-size=900,640",
            "--window-position=60,60",
            "--app=file://\(pageURL.path)",
        ]
        // The browser writes pages of its own diagnostics over the table, and
        // none of it is about the measurement.
        process.standardError = FileHandle.nullDevice
        try process.run()

        var found: ChromeWindow?
        let appeared = LivePump.run(
            until  : {
                found = ChromeWindow.windows(ownedBy: "Google Chrome").first {
                    $0.processID == process.processIdentifier
                        && Self.title(of: $0).contains(titleMark)
                }
                return found != nil
            },
            timeout: timeout
        )
        guard appeared, let found else {
            process.terminate()
            throw FixtureFailure.neverPublished("the browser this suite launched never showed its page")
        }
        return ChromiumTypingTarget(process: process, profile: profile, window: found)
    }

    private init(process: Process, profile: URL, window: ChromeWindow) {
        self.process      = process
        self.profile      = profile
        self.processID    = window.processID
        self.windowNumber = window.windowNumber
        self.frame        = window.frame
    }

    private static func title(of window: ChromeWindow) -> String {
        window.title.isEmpty
            ? ChromeWindow.accessibilityTitle(
                processID   : window.processID,
                windowNumber: window.windowNumber
              )
            : window.title
    }

    private func title() -> String {
        guard let entry = ChromeWindow.windows(ownedBy: "Google Chrome")
            .first(where: { $0.windowNumber == windowNumber })
        else {
            return ""
        }
        frame = entry.frame
        return Self.title(of: entry)
    }

    /// Waits for the page to empty itself, which it does on its own after a
    /// second and a half without a keystroke.
    func reset() -> Bool {
        LivePump.run(until: { self.arrivedCount() == 0 }, timeout: 15)
    }

    func arrivedCount() -> Int { counter("n=") }

    func charactersTaken() -> Int { counter("tc=") }

    func editsApplied() -> Int { counter("te=") }

    /// One `name=number` field of the page's own title, or zero when the window
    /// server has no title to hand over yet.
    private func counter(_ name: String) -> Int {
        for part in title().split(separator: " ") where part.hasPrefix(name) {
            return Int(part.dropFirst(name.count)) ?? 0
        }
        return 0
    }

    let countsCharacters = true

    /// The whole title, which carries the keystrokes the page saw next to the
    /// length of its field: the two disagree when the events reach the renderer
    /// and the field does not take them.
    func diagnostics() -> String { title() }

    /// Ends the browser and takes its profile with it. The wait is not
    /// politeness: a browser still shutting down holds files open, and the
    /// directory stays behind with tens of megabytes in it.
    func terminate() {
        process.terminate()
        _ = LivePump.run(until: { !self.process.isRunning }, timeout: 10)
        try? FileManager.default.removeItem(at: profile)
    }
}

/// One cell of the sweep: what was asked of the target, and how long the target
/// took to have all of it.
nonisolated struct TypingRow {

    let target  : String
    let length  : Int
    let chunk   : Int
    let pauseMs : Int
    let postedMs: Double
    let totalMs : Double
    let arrived : Int
    let handSeen: Bool

    var complete           : Bool   { arrived >= length }
    var millisecondsPerChar: Double { totalMs / Double(length) }

    var line: String {
        String(
            format: "| %-8@ | %5d | %5d | %4d | %9.0f | %9.0f | %6.2f | %-5@ |",
            target, length, chunk, pauseMs, postedMs, totalMs, millisecondsPerChar,
            complete ? (handSeen ? "HAND" : "ok") : "SHORT"
        )
    }
}

/// What a long typed string costs, and whether pacing it changes that.
///
/// `.text` posts two events per character as fast as the window server takes
/// them, and the measured cost per character grows with the length of the
/// string. The question this suite was written for is whether the cause is the
/// driver filling a queue faster than the target drains it, in which case a
/// chunk size and a pause would fix it. The answer measured here is no: on both
/// families the total is the same whether the same string goes out in one burst
/// or is spread over twenty seconds, and it grows with **how much text the
/// target already holds**, which is the target's own insertion cost and not a
/// queue. The grid is kept because it is the evidence, and because the next
/// hardware or the next build may not answer the same way.
///
/// Two rules of method, both learned the hard way. Every wait is a **polling
/// deadline** and never a fixed sleep, or the sleep is what gets measured. And
/// the reading comes from the target: a framework text control reports a value
/// that lags behind what its field editor has applied, so on that target the
/// change counter is trusted over the value read back.
///
/// The knobs, all off by default:
///
/// - `AGENTSEAT_TYPING_SWEEP=1` runs it at all;
/// - `AGENTSEAT_TYPING_TARGETS`, `_LENGTHS`, `_CHUNKS`, `_PAUSES_MS`, `_TIMEOUT_S`
///   are the grid, comma separated;
/// - `AGENTSEAT_TYPING_ONE_EVENT=1` sends the whole string as `.insertText`
///   instead of one key pair per character, which is the control the grid needs;
/// - `AGENTSEAT_TYPING_PREPARE=1` prepares the target for a typed string, which
///   nothing needs and which is kept so the cost of preparing can be priced.
///
/// The pacing is applied **by the caller**, one send per chunk with a pause
/// between: that is what a consumer can do today without the kit changing, and
/// it is what makes this suite an honest test of the proposal. On a family whose
/// typed string is prepared it costs one settle per chunk, so a very small chunk
/// pays for the preparation many times over.
@Suite("What a long typed string costs", .serialized)
@MainActor
struct TypingCostLiveTests {

    /// The longest one run may take before it is called short. Unpaced, 8 192
    /// characters took 70 seconds on the AppKit target, so the ceiling is
    /// generous on purpose: a run that is cut off measures the ceiling.
    static var runTimeout: Double {
        Double(sweepNumbers("AGENTSEAT_TYPING_TIMEOUT_S", [240]).first ?? 240)
    }

    /// Whether the string travels on one key event carrying the whole unicode
    /// string, which is `.insertText`, instead of one pair per character.
    static var oneEventEnabled: Bool {
        ProcessInfo.processInfo.environment["AGENTSEAT_TYPING_ONE_EVENT"] == "1"
    }

    @Test("a long typed string costs what the target's own editor costs",
          .enabled(if: typingSweepSkipReason() == nil,
                   Comment(rawValue: typingSweepSkipReason() ?? "")))
    func theTypingSweep() async throws {

        LivePump.prepare()
        #expect(Permissions.preflight(.postEvent), "Post Event is not granted to the test runner")

        let lengths  = sweepNumbers("AGENTSEAT_TYPING_LENGTHS",   [512, 2_048, 8_192])
        let chunks   = sweepNumbers("AGENTSEAT_TYPING_CHUNKS",    [16, 64, 512])
        let pauses   = sweepNumbers("AGENTSEAT_TYPING_PAUSES_MS", [0, 8, 32])
        let families = ProcessInfo.processInfo.environment["AGENTSEAT_TYPING_TARGETS"]
            ?? "appkit,chromium"

        let driver = try InputDriver(allowUnvalidatedBuild: true)
        var rows: [TypingRow] = []
        var marker: Int64 = 0x7000_0000

        var targets: [any TypingTarget] = []
        if families.contains("appkit")   { targets.append(FixtureTypingTarget()) }
        if families.contains("chromium") { targets.append(try ChromiumTypingTarget.launched()) }
        defer { targets.forEach { $0.terminate() } }

        print("""
            \n| target   | chars | chunk |  ms | posted ms | total  ms | ms/ch | state |
            |----------|-------|-------|-----|-----------|-----------|-------|-------|
            """)

        for target in targets {
            for length in lengths {
                for chunk in chunks {
                    for pause in pauses {
                        // Chunking without a pause is not a second row: the
                        // events go out back to back either way.
                        if pause == 0 && chunk != chunks.first { continue }
                        marker += 1
                        let row = await run(
                            length: length,
                            chunk : chunk,
                            pause : pause,
                            on    : target,
                            driver: driver,
                            marker: marker
                        )
                        rows.append(row)
                        print(row.line)
                        if !row.complete { print("  short: \(target.diagnostics())") }
                    }
                }
            }
        }

        #expect(rows.contains { !$0.handSeen }, "every run saw the person's hand, so this proves nothing")
        #expect(rows.contains { $0.complete },  "no run delivered the whole string")
    }

    /// One run: empty the target, send the string chunk by chunk, then poll the
    /// target's own counter until all of it is there or the deadline passes.
    private func run(
        length: Int,
        chunk : Int,
        pause : Int,
        on target: any TypingTarget,
        driver: InputDriver,
        marker: Int64
    ) async -> TypingRow {

        let ready = target.reset()
        let text  = Self.text(ofLength: length)
        let base  = target.arrivedCount()
        let row   = { (posted: Double, total: Double, arrived: Int, hand: Bool) in
            TypingRow(
                target  : target.name,
                length  : length,
                chunk   : chunk,
                pauseMs : pause,
                postedMs: posted,
                totalMs : total,
                arrived : arrived,
                handSeen: hand
            )
        }
        guard ready else { return row(0, 0, 0, false) }

        // A target that counts edits rather than characters answers 1 when a
        // whole string is inserted at once.
        let expected = Self.oneEventEnabled && !target.countsCharacters ? 1 : length
        // No pause means no pacing at all, which is one send of the whole
        // string: chunking it without waiting would only add sends.
        let pieces   = Self.oneEventEnabled || pause == 0
            ? [text]
            : Self.pieces(of: text, every: chunk)
        let platform = PreparedTextPlatform(base: target.platform)

        let start  = DispatchTime.now().uptimeNanoseconds
        var posted = 0.0
        do {
            for (index, piece) in pieces.enumerated() {
                let command: InputCommand = Self.oneEventEnabled
                    ? .insertText(piece)
                    : .text(piece)
                _ = try await driver.send(
                    command,
                    to           : target.window,
                    correlationID: marker,
                    platform     : platform
                )
                // No pause after the last chunk: everything is out and there is
                // nothing left to drain.
                if pause > 0, index + 1 < pieces.count {
                    LivePump.run(for: Double(pause) / 1_000)
                }
            }
            posted = Self.millisecondsSince(start)
        } catch {
            print("  send refused: \(error)")
        }

        var arrived = target.arrivedCount() - base
        _ = LivePump.run(
            until  : {
                arrived = target.arrivedCount() - base
                return arrived >= expected
            },
            timeout: Self.runTimeout
        )
        let total = Self.millisecondsSince(start)
        if Self.oneEventEnabled { print("  one event: \(target.diagnostics())") }

        return row(
            posted,
            total,
            Self.oneEventEnabled && arrived >= expected ? length : arrived,
            secondsSinceHand() < total / 1_000
        )
    }

    /// The string cut into chunks of `size` characters, which is the pacing a
    /// consumer can apply today with no change to the kit.
    static func pieces(of text: String, every size: Int) -> [String] {
        guard size > 0, size < text.count else { return [text] }
        return stride(from: 0, to: text.count, by: size).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            let to   = text.index(from, offsetBy: min(size, text.count - start))
            return String(text[from..<to])
        }
    }

    private static func millisecondsSince(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }

    /// Plain lowercase letters: no newline, which a single line text control
    /// reads as the end of editing, and no modifier anywhere.
    static func text(ofLength length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        return String((0..<length).map { alphabet[$0 % alphabet.count] })
    }
}
