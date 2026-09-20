import Foundation

/// PeekOptions validates the inspection command before it requests permissions or creates panels.
struct PeekOptions {
    var intervalMilliseconds = 500
    var durationSeconds: Double?
    var sectionsOnly = false
    var labels = false
    var timings = false
    var help = false

    init(arguments: [String]) throws {
        var index = 0
        var seen = Set<String>()
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else {
                throw UsageError.invalid(option: "peek", value: option, expected: "each option only once")
            }
            switch option {
                case "--help", "-h": help = true
                case "--sections-only": sectionsOnly = true
                case "--labels": labels = true
                case "--timings": timings = true
                case "--interval-ms", "--duration":
                    guard index + 1 < arguments.count else { throw UsageError.missing("\(option) <number>") }
                    index += 1
                    let value = arguments[index]
                    if option == "--interval-ms" {
                        guard let number = Int(value), (100...60_000).contains(number) else {
                            throw UsageError.invalid(option: "interval-ms", value: value, expected: "100...60000")
                        }
                        intervalMilliseconds = number
                    } else {
                        guard let number = Double(value), number.isFinite, number > 0, number <= 86_400 else {
                            throw UsageError.invalid(option: "duration", value: value, expected: "seconds in (0, 86400]")
                        }
                        durationSeconds = number
                    }
                default:
                    throw UsageError.invalid(option: "peek", value: option, expected: "mecum peek --help")
            }
            index += 1
        }
    }

    static let usage = """
    mecum peek [--sections-only] [--labels] [--interval-ms 500] [--duration <seconds>] [--timings]

    Draw the production perception scene over the frontmost app. Start this command, then bring
    the desired app forward. The overlay follows its interaction window and open popups.
    Cyan: native controls. Orange: pixel text or caption groups. Green: visual icons.
    Purple: image surfaces. Yellow: uncertain media overlays. Dashed pink: panel boundaries.

    --sections-only     draw panel boundaries without element boxes
    --labels            include element and panel names (can be dense)
    --interval-ms <n>   minimum time between observation starts; default 500, minimum 100
    --duration <n>      stop automatically after this many seconds; otherwise Ctrl+C stops
    --timings           report observation-to-draw latency and discarded observations

    Click-through, no focus activation, no Seat, no provider calls, no memory writes.
    Screen Recording is required; Accessibility adds native control names and states.
    Boxes clear on input or a target change. They are observations, not proof of clickability.
    """
}
