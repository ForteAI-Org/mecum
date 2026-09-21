import Foundation

/// WHICH APP A TOOL CALL WAS ABOUT — resolved in ONE place, because a Turn with no app is a Turn that
/// recall can never find again (`recentTurns(app:)` filters on it, and ticket 11's identity model hangs
/// everything off app + state).
///
/// Measured 2026-09-10 on the transcript ledger's first real row: `app` came out EMPTY even though the
/// turn's own `do_in_app(app: "pro tools")` had said so, because the frontend only ever read `app` off a
/// call whose outcome began `found_acted`. Two blind spots, both on the API path the pro apps PREFER —
/// so the better the engine routes, the less the ledger learns:
///   • `app_call` nests the real arguments one level down (and the model often passes them as a JSON
///     *string*, not an object), and carries no `app` of its own;
///   • adapter verbs like `ptsl_tracks` / `resolve_timelines` never act — they READ — so `found_acted`
///     never arrives and nothing was captured at all.
///
/// Three layers, most-trusted first: the call's own `app` argument, then `app_call`'s nested one, then
/// the verb NAMESPACE (`ptsl_*` IS Pro Tools by construction, whether it arrives as a direct tool or
/// through `app_call`). The namespace table mirrors only the PREFIXES, never the verb list, so a new
/// verb costs it nothing; `ToolCallAppTests` holds it against `CapabilityCatalog` so a new adapter
/// family cannot drift away unnoticed. Nothing is guessed: a call that names no app resolves to nil.
public enum ToolCallApp {

    /// The app a tool call names, or nil when nothing in the call says which.
    public static func resolve(tool: String, args: [String: Any]) -> String? {
        if let own = nonEmpty(args["app"]) { return own }
        if let nested = nestedArgs(args), let inner = nonEmpty(nested["app"]) { return inner }
        // `app_call(verb:)` carries the real verb; a direct adapter tool IS its own verb.
        return namespaceApp(nonEmpty(args["verb"]) ?? tool)
    }

    /// Which app a verb NAMESPACE belongs to. `app_*` is the OS-wide gateway (`app_command_surface`,
    /// `app_capabilities`): it names no app by itself — its own `app` argument does, which layers 1–2
    /// have already tried by the time we get here.
    static let namespaces: [String: String] = [
        "ptsl": "pro tools",
        "resolve": "davinci resolve",
        "premiere": "premiere",
        "ps": "photoshop",
        "finder": "finder",
        "notes": "notes",
        "music": "music",
    ]

    static func namespaceApp(_ verb: String) -> String? {
        guard let prefix = verb.split(separator: "_").first, verb.contains("_") else { return nil }
        return namespaces[String(prefix).lowercased()]
    }

    /// `app_call`'s nested arguments, whether the model sent an object or a JSON string.
    static func nestedArgs(_ args: [String: Any]) -> [String: Any]? {
        if let dict = args["args"] as? [String: Any] { return dict }
        if let raw = args["args"] as? String, let data = raw.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return dict }
        return nil
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
