//
//  ChildProcessIdentity.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Darwin
import Foundation

/// ChildProcessIdentity names one process well enough to tell it apart from
/// any later process that is given the same pid.
///
/// A provider child can outlive a crashed app: nothing ends it until it next
/// writes to the pipe the app held. The identity is taken when the child is
/// spawned and recorded, so a later launch can end that child and only that
/// child. The pid alone proves nothing once the process is gone, so the start
/// time and the executable are part of the identity.
public nonisolated struct ChildProcessIdentity: Sendable, Hashable, Codable {

    public let pid              : Int32
    public let startSeconds     : Int
    public let startMicroseconds: Int32
    public let executablePath   : String

    /// The process running at `pid` now, or nil when there is none or its
    /// start time or executable cannot be read.
    public init?(running pid: Int32) {
        guard let reading = Self.read(pid) else { return nil }
        self.pid               = pid
        self.startSeconds      = reading.startSeconds
        self.startMicroseconds = reading.startMicroseconds
        self.executablePath    = reading.executablePath
    }

    /// Sends SIGTERM when the process at `pid` is still this one and has lost
    /// the parent that spawned it, and returns whether a signal was sent.
    ///
    /// A process with the same pid and another start time or executable is
    /// someone else's and is left alone, as is this process while any parent
    /// other than launchd still holds it.
    public func endIfOrphaned() -> Bool {
        guard let now = Self.read(pid),
              now.startSeconds == startSeconds, now.startMicroseconds == startMicroseconds,
              now.executablePath == executablePath, now.parent == 1
        else { return false }
        return kill(pid, SIGTERM) == 0
    }

    private struct Reading {
        let startSeconds     : Int
        let startMicroseconds: Int32
        let executablePath   : String
        let parent           : Int32
    }

    private static func read(_ pid: Int32) -> Reading? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // A pid with no process answers success with nothing written.
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid
        else { return nil }

        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Reading(
            startSeconds     : start.tv_sec,
            startMicroseconds: start.tv_usec,
            executablePath   : String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self),
            parent           : info.kp_eproc.e_ppid
        )
    }
}
