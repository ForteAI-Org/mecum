//
//  MarkerTable.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// MarkerTable maps a synthetic marker to one value, with the single property
/// the fence callback needs: **reading, updating and iterating it never
/// allocates**. A `Dictionary` cannot promise that here, because following the
/// anchors while a synthetic action is in flight means mutating it during
/// iteration, which means `Array(keys)` first: one heap allocation for every
/// physical mouse event during every action, measured at 1.00 alloc per event.
///
/// A flat array of pairs has none of that. Insertion and removal happen on the
/// consumer's thread while a Command is being prepared, so the growth those can
/// trigger is outside the callback; the callback only looks up, writes in place
/// and walks the entries. Two or three markers is the realistic size, so the
/// linear scan beats hashing anyway.
nonisolated struct MarkerTable<Value> {

    /// One marker and its value. A tuple would work too; the named fields make
    /// the callback readable at the point where it matters.
    struct Entry {
        let marker: Int64
        var value : Value
    }

    /// How many markers the table reserves room for up front. Past it the array
    /// grows, which is fine: growth only ever happens on `insert`, never in the
    /// callback.
    static var reservedCapacity: Int { 8 }

    private(set) var entries: [Entry] = []

    init() {
        entries.reserveCapacity(Self.reservedCapacity)
    }

    var isEmpty: Bool { entries.isEmpty }
    var count  : Int  { entries.count }

    /// The value for a marker, or nil. Linear scan, no allocation.
    func value(for marker: Int64) -> Value? {
        for entry in entries where entry.marker == marker {
            return entry.value
        }
        
        return nil
    }

    /// Replaces the value for an existing marker or appends a new one, so a
    /// second `begin` for the same marker refreshes it instead of duplicating.
    mutating func insert(
        _   value : Value,
        for marker: Int64
    ) {
        for index in entries.indices where entries[index].marker == marker {
            entries[index].value = value
            return
        }
        entries.append(Entry(marker: marker, value: value))
    }

    /// Removes the marker if it is there, and says whether it was.
    @discardableResult
    mutating func remove(_ marker: Int64) -> Value? {
        for index in entries.indices where entries[index].marker == marker {
            return entries.remove(at: index).value
        }
        return nil
    }

    /// Empties the table, keeping the buffer so the next action does not
    /// reallocate it.
    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Writes the same value into every entry. This is the operation the
    /// `Dictionary` could not do without allocating, and the reason this type
    /// exists: while an action is in flight the fence keeps following the
    /// person's real cursor, so the next synthetic event is pinned to the most
    /// recent physical position rather than to the one the action started at.
    mutating func setAll(_ value: Value) {
        for index in entries.indices { entries[index].value = value }
    }
}
