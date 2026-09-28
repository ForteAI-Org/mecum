import Foundation

/// WatchOptions validates the passive diagnostic command without starting a tap or reading an app.
struct WatchOptions {
    var app: String?
    var raw = false
    var json = false
    var hover = true
    var duration: Double?
    var intervalMilliseconds = 500
    var help = false

    init(arguments: [String]) throws {
        var index = 0
        var seen = Set<String>()
        while index < arguments.count {
            let option = arguments[index]
            if !option.hasPrefix("-") {
                guard app == nil else { throw UsageError.invalid(option: "watch", value: option, expected: "one optional app") }
                app = option
                index += 1
                continue
            }
            guard seen.insert(option).inserted else {
                throw UsageError.invalid(option: "watch", value: option, expected: "each option once")
            }
            switch option {
            case "--help", "-h": help = true
            case "--raw": raw = true
            case "--json": json = true
            case "--no-hover": hover = false
            case "--duration", "--interval-ms":
                guard index + 1 < arguments.count else { throw UsageError.missing("\(option) <number>") }
                index += 1
                let value = arguments[index]
                if option == "--duration" {
                    guard let number = Double(value), number.isFinite, number > 0, number <= 86400 else {
                        throw UsageError.invalid(option: option, value: value, expected: "seconds in (0, 86400]")
                    }
                    duration = number
                } else {
                    guard let number = Int(value), (100...60000).contains(number) else {
                        throw UsageError.invalid(option: option, value: value, expected: "100...60000")
                    }
                    intervalMilliseconds = number
                }
            default: throw UsageError.invalid(option: "watch", value: option, expected: "mecum watch --help")
            }
            index += 1
        }
    }

    static let usage = """
    mecum watch [<app>] [--raw] [--json] [--no-hover] [--duration <seconds>] [--interval-ms 500]

    Listen to manual clicks, right-clicks, settled scroll gestures, app focus and hover dwell.
    Start this command, then work in the target app. Wait for 'ready' before testing a click.
    The optional running app is a name or bundle id; otherwise all application owners are reported.

    --raw              input and window attribution only, without AX or screenshot perception
    --json             one JSON object per event on stdout; health/readiness stays on stderr
    --no-hover         disable the 1.2-second hover dwell
    --duration <n>     stop automatically after n seconds; Ctrl+C and SIGTERM also stop cleanly
    --interval-ms <n>  ambient perception cadence, 100...60000 ms; default 500

    Input Monitoring is required. Perception also needs Screen Recording; Accessibility adds AX.
    BEFORE identifies a control only from a recent, uninterrupted pre-event scene of the same window.
    AFTER and AX are current diagnostic readings, never substitutes for a missing BEFORE.
    name= compares the hit with Mecum's production label resolver. Pixel-only hits are observations,
    not proof of clickability. Rapid input can legitimately produce unresolved events.

    No input is sent, no Seat is created, no provider is called, and no memory or files are written.
    Keyboard text and drag paths are not recorded. Scroll dx/dy are in screen points.
    """
}
