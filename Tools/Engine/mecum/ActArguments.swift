import EngineCore
import PerceptionCore

/// ActArguments validates an action before a Seat or application is needed.
struct ActArguments {

    let target: String
    let verb: ActionVerb
    let section: String?
    let desiredState: ControlState?

    init(_ invocation: Invocation, targetIndex: Int = 1) throws {
        target = try invocation.positional(targetIndex, "<target>")
        let word = invocation.options["verb"] ?? "click"
        guard let verb = ActionVerb(rawValue: word) else {
            throw UsageError.invalid(option: "verb", value: word,
                                     expected: ActionVerb.allCases.map(\.rawValue).joined(separator: "|"))
        }
        self.verb = verb
        section = invocation.options["section"]
        if let value = invocation.options["value"] {
            guard let state = ControlState(rawValue: value), state == .on || state == .off else {
                throw UsageError.invalid(option: "value", value: value, expected: "on|off")
            }
            desiredState = state
        } else {
            desiredState = nil
        }
        if verb == .setToggle, desiredState == nil {
            throw UsageError.missing("--value on|off for set_toggle")
        }
    }
}
