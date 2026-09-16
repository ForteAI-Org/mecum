//
//  KeyboardLayoutCache.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore

/// KeyboardLayoutSource is one owned reading of the system data that determines
/// keyboard translation.
///
/// The data is copied at the system boundary before this value is built. Its
/// identity includes the source id, keyboard hardware type and Key Table
/// version because any of them can change the rows produced by translation.
nonisolated package struct KeyboardLayoutSource: Sendable {
    package let inputSourceID: String
    package let layoutData   : Data
    package let keyboardType : UInt32
    package let tableVersion : Int

    package init(
        inputSourceID: String,
        layoutData   : Data,
        keyboardType : UInt32,
        tableVersion : Int = KeyNames.version
    ) {
        self.inputSourceID = inputSourceID
        self.layoutData    = layoutData
        self.keyboardType  = keyboardType
        self.tableVersion  = tableVersion
    }
}

/// KeyboardLayoutCache owns the last translated source and its monotonic
/// process generation.
///
/// A byte change invalidates the entry even when `UCKeyTranslate` would produce
/// identical rows. The generation therefore describes source identity, not
/// merely the visible character maps. An unavailable or untranslatable source
/// clears the reusable entry, so a later call cannot return a stale layout.
nonisolated package struct KeyboardLayoutCache: Sendable {

    package typealias Rows = [Modifiers: [CGKeyCode: Character]]

    private struct Entry: Sendable {
        let source: KeyboardLayoutSource
        let layout: KeyboardLayout
    }

    private var entry         : Entry?
    private var lastGeneration: UInt64 = 0

    package init() {}

    /// Returns the cached layout for an exactly equal source, or translates and
    /// records a changed source. The translator runs only after exact identity
    /// comparison says the previous result cannot be reused.
    package mutating func layout(
        for source: KeyboardLayoutSource?,
        translating translate: (Data, UInt32) -> Rows
    ) -> KeyboardLayout? {
        guard let source else {
            entry = nil
            return nil
        }
        if let entry, Self.equal(entry.source, source) {
            return entry.layout
        }

        let rows = translate(source.layoutData, source.keyboardType)
        guard let characters = rows[[]], !characters.isEmpty else {
            entry = nil
            return nil
        }

        lastGeneration &+= 1
        if lastGeneration == 0 { lastGeneration = 1 }
        let layout = KeyboardLayout(
            inputSourceID         : source.inputSourceID,
            generation            : lastGeneration,
            tableVersion          : source.tableVersion,
            characters            : characters,
            modifiedCharactersByKey: rows
        )
        entry = Entry(source: source, layout: layout)
        return layout
    }

    private static func equal(
        _ lhs: KeyboardLayoutSource,
        _ rhs: KeyboardLayoutSource
    ) -> Bool {
        lhs.inputSourceID == rhs.inputSourceID
            && lhs.keyboardType == rhs.keyboardType
            && lhs.tableVersion == rhs.tableVersion
            && SIMDByteComparison.equal(lhs.layoutData, rhs.layoutData)
    }
}
