//
//  CommandSpecs.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Memory

/// CommandSpecs is what each vertical command takes, as `Invocation`'s grammar checks it: every
/// option a command does not name is refused, before a Seat, an application or the memory is touched.
enum CommandSpecs {

    /// The shared options of a command that drives an application.
    static let driving = OptionSpec(valued: ["knowledge", "window"],
                                    flags: ["seat", "allow-unvalidated-build", "allow-destructive", "dry-run"])

    /// A direct action: the shared options, `--evidence` for `select`, and the operation's own.
    static func action(_ tool: AgentTool) -> OptionSpec {
        let own = tool == .select ? OptionSpec(valued: ["evidence"]) : OptionSpec()
        return driving.merging(own).merging(ActionGrammar.spec(tool))
    }

    /// A batch's header, before `--`: no `--dry-run`.
    static let batch = OptionSpec(valued: ["window", "knowledge", "evidence"],
                                  flags: ["seat", "allow-unvalidated-build", "allow-destructive"])

    static let scene = OptionSpec(valued: ["knowledge", "window"], flags: ["json", "seat", "allow-unvalidated-build"])

    static let windows = OptionSpec()

    static let memory = OptionSpec(valued: ["knowledge", "after", "before", "limit"], flags: ["detail"])
}
