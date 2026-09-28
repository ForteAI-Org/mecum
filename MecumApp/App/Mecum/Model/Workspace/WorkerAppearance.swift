//
//  WorkerAppearance.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// WorkerAppearance is the persisted descriptor a mascot is generated from.
///
/// It is stored, not derived, so the same worker draws the same way between
/// launches and between generator builds. Renaming the worker or changing its
/// role, model or provider must leave every field here untouched; only an
/// explicit regenerate writes a new `seed`. `generatorVersion` records which
/// generator the descriptor was made for, so a later generator can keep drawing
/// an older worker the way it always looked.
nonisolated struct WorkerAppearance: Codable, Hashable, Sendable {

    /// Deterministic input of the generator. Stable across relaunches.
    ///
    /// Signed because SwiftData carries a Codable attribute through
    /// `NSNumber`, which cannot bridge `UInt64` and traps on the attempt. It
    /// is still 64 bits of seed: a generator that wants an unsigned one reads
    /// `UInt64(bitPattern:)`.
    var seed: Int64

    /// The generator build this descriptor was authored against.
    var generatorVersion: Int

    /// Name of the colour set the generator resolves. A name rather than
    /// components, so the store holds no colour type and a palette can be
    /// retuned without rewriting every worker.
    var palette: String

    /// Shape parameters, each in 0...1. They are the few knobs the first
    /// generator exposes, not a general shader interface.
    var roundness: Double
    var wobble   : Double
    var glow     : Double

    init(
        seed            : Int64,
        generatorVersion: Int    = 1,
        palette         : String,
        roundness       : Double = 0.5,
        wobble          : Double = 0.5,
        glow            : Double = 0.5
    ) {
        self.seed             = seed
        self.generatorVersion = generatorVersion
        self.palette          = palette
        self.roundness        = roundness
        self.wobble           = wobble
        self.glow             = glow
    }
}
