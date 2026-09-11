//
//  InputTraceStage.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// InputTraceCount makes an unavailable runtime count explicit. Timing a live
/// Command does not install an allocator hook or inspect process memory: those
/// operations would perturb the path they claim to describe. A benchmark can
/// replace `unknown` with a measured count when it owns the process and the
/// control.
public enum InputTraceCount: Sendable, Equatable {
    case known(Int)
    case unknown
}

/// InputTraceStage is one fixed part of a Command's temporal trace.
///
/// The interval says when the stage occupied the transaction. The costs say
/// which measured wall intervals were local work, calls into the running
/// system, required Platform waits or executor scheduling waits. Opaque async
/// prerequisites stay unattributed instead of being relabelled as OS time.
/// These fields are wall intervals, not thread CPU time. A stage that did not
/// run keeps both bounds nil, which is different from a stage that ran too
/// quickly for the monotonic clock to distinguish.
public struct InputTraceStage: Sendable, Equatable {

    public let startedAtNanoseconds : UInt64?
    public let completedAtNanoseconds: UInt64?
    public let workNanoseconds      : UInt64
    public let systemCallNanoseconds: UInt64
    public let intentionalWaitNanoseconds: UInt64
    public let schedulingWaitNanoseconds : UInt64
    public let unattributedNanoseconds    : UInt64
    public let allocationCount      : InputTraceCount
    public let copyCount            : InputTraceCount

    public init(
        startedAtNanoseconds      : UInt64? = nil,
        completedAtNanoseconds    : UInt64? = nil,
        workNanoseconds           : UInt64 = 0,
        systemCallNanoseconds     : UInt64 = 0,
        intentionalWaitNanoseconds: UInt64 = 0,
        schedulingWaitNanoseconds : UInt64 = 0,
        unattributedNanoseconds    : UInt64 = 0,
        allocationCount           : InputTraceCount = .unknown,
        copyCount                 : InputTraceCount = .unknown
    ) {
        self.startedAtNanoseconds       = startedAtNanoseconds
        self.completedAtNanoseconds     = completedAtNanoseconds
        self.workNanoseconds            = workNanoseconds
        self.systemCallNanoseconds      = systemCallNanoseconds
        self.intentionalWaitNanoseconds = intentionalWaitNanoseconds
        self.schedulingWaitNanoseconds  = schedulingWaitNanoseconds
        self.unattributedNanoseconds     = unattributedNanoseconds
        self.allocationCount            = allocationCount
        self.copyCount                  = copyCount
    }

    /// True when the transaction reached this stage.
    public var wasPerformed: Bool {
        startedAtNanoseconds != nil && completedAtNanoseconds != nil
    }
}
