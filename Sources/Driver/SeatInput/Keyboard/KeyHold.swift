//
//  KeyHold.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import SeatCore
import Synchronization

/// KeyHold is what the kit is holding down on a target process, and it exists
/// because a `.down` without its `.up` is a real key left pressed inside
/// somebody else's application.
///
/// It holds **keys**, not only modifiers. A letter held down leaks exactly the
/// same way a Command key does, and a registry that tracked only modifiers
/// would give the cleanup nothing to release. The modifiers are the subset
/// whose virtual key is one, derived on demand, and that subset is what stamps
/// the flags of the next Command.
///
/// ## Why per process and not per driver
///
/// Two windows of the same application are one AppKit process with one idea of
/// what is held, so the PID is the boundary the system actually has. That is a
/// hypothesis, not a measurement: the matrix row that drives two windows of the
/// same target is what confirms or falsifies it, and if it falsifies it the key
/// of this registry is what changes.
///
/// ## Why per Turn inside that
///
/// Cleanup has to release what **this** holder pressed and nothing else. Two
/// Turns can hold keys on the same process, and one giving its seat back must
/// not release the other's. The owner is the Turn's correlation ID, which is
/// already threaded through every send.
///
/// The registry lives beside `InputTargetExclusion.shared` and deliberately not
/// inside it: an exclusion entry exists only while a lease does, and a held key
/// has to outlive the Command that pressed it.
nonisolated package final class KeyHold: Sendable {

    /// HeldKey is one key this session is holding, and the character it was
    /// resolved from when it was resolved from one.
    ///
    /// The character is kept for one reason: the person can change keyboard
    /// layout between the press and the release. Resolving the character again
    /// under the new layout would give a different virtual key, so the release
    /// would lift a key that was never pressed and leave this one down forever.
    /// What went down is what comes up.
    package struct HeldKey: Sendable, Equatable {

        package let virtualKey: CGKeyCode
        package let character : Character?

        package init(virtualKey: CGKeyCode, character: Character? = nil) {
            self.virtualKey = virtualKey
            self.character  = character
        }
    }

    package static let shared = KeyHold()

    /// Ordered per owner, because a release walks it backwards: the last key
    /// pressed is the first released, which is what a hand does and what keeps
    /// a modifier held around the key it was modifying until that key is up.
    private struct State {
        var targets: [Int32: [Int64: [HeldKey]]] = [:]
    }

    private let state = Mutex(State())

    package init() {}

    /// Records a key as held. Answers false when this owner already holds it,
    /// which is the caller's signal that no press event should be built: a
    /// second down for a key already down is an autorepeat, and that is a phase
    /// of its own.
    @discardableResult
    package func press(
        _ key    : HeldKey,
        owner    : Int64,
        processID: Int32
    ) -> Bool {
        state.withLock { state in
            var keys = state.targets[processID]?[owner] ?? []
            guard !keys.contains(where: { $0.virtualKey == key.virtualKey }) else { return false }
            keys.append(key)
            state.targets[processID, default: [:]][owner] = keys
            return true
        }
    }

    /// Forgets one held key. Answers false when this owner was not holding it,
    /// so a release nobody asked for builds no event.
    @discardableResult
    package func release(
        virtualKey: CGKeyCode,
        owner     : Int64,
        processID : Int32
    ) -> Bool {
        state.withLock { state in
            guard var keys = state.targets[processID]?[owner],
                  let index = keys.firstIndex(where: { $0.virtualKey == virtualKey })
            else {
                return false
            }
            keys.remove(at: index)
            Self.store(keys, owner: owner, processID: processID, in: &state)
            return true
        }
    }

    /// Forgets everything this owner holds and answers it in release order,
    /// last pressed first. This is what a Turn's release posts.
    package func releaseAll(owner: Int64, processID: Int32) -> [HeldKey] {
        state.withLock { state in
            let keys = state.targets[processID]?[owner] ?? []
            Self.store([], owner: owner, processID: processID, in: &state)
            return keys.reversed()
        }
    }

    /// Forgets everything every owner holds on this process and answers it.
    ///
    /// For the terminal case only: a seat that has failed has no Turn left to
    /// refuse, so there is nobody to hand the keys back to. It clears the kit's
    /// own bookkeeping, which would otherwise make the next Turn on this process
    /// stamp modifiers nobody is holding. It does **not** lift the keys inside
    /// the target, which is why the caller reports an Issue: under the default
    /// modifier policy the target was never told, but an ordinary key really did
    /// go down without its up and the kit cannot fix that from a failed seat.
    package func releaseEveryOwner(processID: Int32) -> [HeldKey] {
        state.withLock { state in
            let owners = state.targets.removeValue(forKey: processID) ?? [:]
            return owners.keys.sorted().flatMap { owners[$0] ?? [] }
        }
    }

    /// Every key held on this process, by every owner, in press order.
    package func held(processID: Int32) -> [HeldKey] {
        state.withLock { state in
            guard let owners = state.targets[processID] else { return [] }
            return owners.keys.sorted().flatMap { owners[$0] ?? [] }
        }
    }

    /// The keys this one owner holds on this process, in press order.
    package func held(owner: Int64, processID: Int32) -> [HeldKey] {
        state.withLock { $0.targets[processID]?[owner] ?? [] }
    }

    /// The modifiers held on this process, which is what the next Command's
    /// flags carry on top of its own.
    package func modifiers(processID: Int32) -> Modifiers {
        held(processID: processID).reduce(into: Modifiers()) { modifiers, key in
            if let modifier = Modifiers(virtualKey: key.virtualKey) {
                modifiers.insert(modifier)
            }
        }
    }

    /// The key this owner is holding that was resolved from `character`, if
    /// any. It is what makes a release survive the person changing layout
    /// halfway through: the release asks what went down rather than resolving
    /// the character again.
    package func heldVirtualKey(
        resolvedFrom character: Character,
        owner    : Int64,
        processID: Int32
    ) -> CGKeyCode? {
        state.withLock { state in
            state.targets[processID]?[owner]?
                .first { $0.character == character }?
                .virtualKey
        }
    }

    /// The number of retained PID entries, for tests and for the leak check an
    /// exclusion registry of the same shape already exposes.
    package var retainedTargetCount: Int {
        state.withLock { $0.targets.count }
    }

    /// Writes an owner's list back, dropping the owner and then the PID when
    /// nothing is left. A registry that kept an empty dictionary per process
    /// ever touched would grow for the life of the process.
    private static func store(
        _ keys   : [HeldKey],
        owner    : Int64,
        processID: Int32,
        in state : inout State
    ) {
        if keys.isEmpty {
            state.targets[processID]?[owner] = nil
            if state.targets[processID]?.isEmpty == true {
                state.targets[processID] = nil
            }
        } else {
            state.targets[processID, default: [:]][owner] = keys
        }
    }
}
