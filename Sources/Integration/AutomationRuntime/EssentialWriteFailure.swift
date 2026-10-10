//
//  EssentialWriteFailure.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation
import Memory

/// EssentialWriteFailure is an essential fact the archive did not confirm, sorted by what the producer
/// does next. Before an effect, every case means the same thing: the gesture does not go out. After an
/// effect, the fact is kept in the service's memory and retried with the same identity before any new
/// effect (`suspended`), and the effect itself is never repeated. The sentence names the kind of
/// failure and never a value the agent typed or read.
public enum EssentialWriteFailure: Error, Sendable, Equatable, CustomStringConvertible {

    /// The memory cannot be used: it could not be opened, or it closed.
    case unavailable(String)

    /// An earlier fact written after an effect is still not confirmed: no new effect until it is.
    case suspended(String)

    /// Another holder kept the archive's lock past the essential budget.
    case contention(String)

    /// The device is full.
    case storageFull(String)

    /// The archive or its directory cannot be written.
    case permission(String)

    /// The device or the file failed while writing.
    case io(String)

    /// The fact's identity already holds other content: a defect of the producer, never retried.
    case conflict(String)

    /// The contract or the schema refused the fact as it was offered: never retried as it is.
    case refused(String)

    /// The caller's task was cancelled before the fact was confirmed.
    case cancelled

    /// Whether offering the same fact again may succeed: contention, a full device and an I/O failure
    /// may pass; a refusal, a conflict, a permission and an unusable memory do not.
    public var isRetryable: Bool {
        switch self {
            case .contention, .storageFull, .io: true
            default                            : false
        }
    }

    /// Whether the archive refused the fact as it was offered: offering it again, as it is, never helps.
    public var isRefusal: Bool {
        switch self {
            case .refused, .conflict: true
            default                 : false
        }
    }

    public var description: String {
        switch self {
            case .unavailable(let why): "the memory is unavailable: \(why)"
            case .suspended(let why)  : "the memory is suspended until an earlier fact is saved: \(why)"
            case .contention(let why) : "the archive stayed locked by another holder: \(why)"
            case .storageFull(let why): "the device is full: \(why)"
            case .permission(let why) : "the archive cannot be written: \(why)"
            case .io(let why)         : "the device failed while writing: \(why)"
            case .conflict(let why)   : "another fact holds this identity: \(why)"
            case .refused(let why)    : "the fact was refused: \(why)"
            case .cancelled           : "cancelled before the fact was saved"
        }
    }

    /// The failure an error of the store, the service or a contract is, by the library's codes where it
    /// gives them: 13 full, 3/8 permission or read only, 14 cannot open, 10/11/26 I/O or corruption.
    public init(_ error: any Error) {
        let why = MemoryService.describe(error)
        switch error {
            case let failure as EssentialWriteFailure:
                self = failure
            case is MemoryUnavailable:
                self = .unavailable(why)
            case is CancellationError:
                self = .cancelled
            case let store as MemoryStoreError:
                switch store {
                    case .contention:
                        self = .contention(why)
                    case .cancelled:
                        self = .cancelled
                    case .identity:
                        self = .conflict(why)
                    case .contract, .malformedText, .snapshot:
                        self = .refused(why)
                    case .unavailable, .schema:
                        self = .unavailable(why)
                    case .open(let fault), .failed(let fault), .locked(let fault):
                        switch fault.code.primary {
                            case 13           : self = .storageFull(why)
                            case 3, 8, 14, 23 : self = .permission(why)
                            case 5, 6         : self = .contention(why)
                            default           : self = .io(why)
                        }
                }
            default:
                // A contract's typed refusal (a call, a task, a fact, an observation): the fact as offered.
                self = .refused(why)
        }
    }
}
