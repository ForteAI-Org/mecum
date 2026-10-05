//
//  BrainApplicationStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// BrainApplicationStoring applies an observation, a record or a naming to an application's brain
/// once per key, durably. Inside one serialized transaction a conformer checks the references the
/// key names, looks the key up, and either answers the stored outcome of an application already
/// concluded, when the offered command is exactly the stored one, or runs the current algorithm on
/// the stored projection at the application's effective clock and writes the difference, the
/// justified evidence and the application with its full input and outcome. An application that
/// changed nothing is concluded all the same. A different command under a concluded key is a
/// conflict and changes nothing; a failure rolls everything back and concludes nothing.
///
/// This is the path a producer uses. `BrainStoring` stays the raw projection: it applies every call
/// again, and only tests and low-level tools call its mutations.
public protocol BrainApplicationStoring: Sendable {

    /// Applies the command, or answers how it was already applied. The answer comes after the commit.
    func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult

    /// The concluded application under a key, read back whole, or nil when none is stored.
    func application(_ key: BrainApplicationKey) async throws -> BrainApplication?
}
