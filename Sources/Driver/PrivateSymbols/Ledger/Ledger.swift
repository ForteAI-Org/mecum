//
//  Ledger.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation

/// FacilityVerdict is what the Ledger says about one Facility on one build. It
/// is **derived** from the primitive rows every time it is asked for and never
/// read from the file: a hand-written verdict is a promise nobody re-checked
/// when a primitive was downgraded.
nonisolated public enum FacilityVerdict: String, Sendable, Equatable {

    /// Every primitive the Facility needs is `verified` on this build.
    case validated

    /// Every primitive is present but at least one is `limited`.
    case limited

    /// A primitive is missing from the entry, filed under another kind, or
    /// `untested`.
    case unvalidated
}

/// Ledger is the kit's record, per macOS build and hardware model, of every
/// primitive it relies on. It travels as a package resource and is read with
/// `Bundle.module`, so a consumer cannot swap it: promotion is a human act on
/// this repository, never a runtime setting.
///
/// The Ledger is only half of the gate. It is what was measured on some machine
/// at some date; the self checks are what is true here and now, and where the
/// two disagree the running system wins.
nonisolated public struct Ledger: Sendable, Decodable {

    /// The file's schema, so an older kit refuses a newer file instead of
    /// reading it half right.
    public let schemaVersion: Int

    /// Entries by `kern.osversion`.
    public let builds: [String: Entry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case builds
    }

    /// The schema this kit reads.
    public static let supportedSchemaVersion = 1

    /// One validated build, with the hardware list that grows as the same build
    /// is promoted on more Macs.
    public struct Entry: Sendable, Decodable {
        public let productVersion: String
        public let hardware      : [String]
        public let validatedAt   : String
        public let validatedBy   : String
        public let primitives    : [String: Primitive]
    }

    /// One primitive on one build. `image` is present for the kinds that have
    /// one, because a spelling without an image does not identify an export.
    public struct Primitive: Sendable, Decodable {
        public let kind  : PrimitiveKind
        public let image : String?
        public let state : PrimitiveState
        public let checks: Checks
        public let notes : String?
    }

    /// What the compatibility suite actually ran. Every field is optional
    /// because the steps that apply depend on the kind: a behaviour has an
    /// observation and no ABI, a record has a length and no setter.
    public struct Checks: Sendable, Decodable, Equatable {
        public let resolves       : Bool?
        public let recordLength   : Int?
        public let allocatedLength: Int?
        public let offsets        : [String: Offset]?
        public let effect         : String?
        public let observed       : Bool?
    }

    /// One offset of a record and the public or private setter that proved it.
    /// `roundTrip` is the only field that decides anything: an offset written by
    /// hand and never read back is an assumption, which is what this whole file
    /// exists to remove.
    public struct Offset: Sendable, Decodable, Equatable {
        public let field    : Int?
        public let setter   : String?
        public let roundTrip: Bool
    }

    /// The Ledger shipped with this build of the kit, decoded once. Loading is
    /// a `Result` so the failure survives the memoisation: a corrupt resource
    /// must keep failing, not silently retry on every Facility start.
    private static let loaded: Result<Ledger, SystemFailure> = {
        let name = "validated-builds"
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            return .failure(.ledgerResourceMissing(name: "\(name).json"))
        }
        do {
            return .success(try Ledger(contentsOf: url))
        } catch let failure as SystemFailure {
            return .failure(failure)
        } catch {
            return .failure(.ledgerUnreadable(reason: "\(error)"))
        }
    }()

    /// The bundled Ledger.
    public static func bundled() throws -> Ledger {
        try loaded.get()
    }

    public init(contentsOf url: URL) throws {
        do {
            try self.init(data: Data(contentsOf: url))
        } catch let failure as SystemFailure {
            throw failure
        } catch {
            throw SystemFailure.ledgerUnreadable(reason: "\(error)")
        }
    }

    /// Decoding is strict by design: an unknown `state` or `kind`, or a missing
    /// `checks`, throws instead of degrading to a default. A Ledger that reads a
    /// row it does not understand is worse than no Ledger, because it answers
    /// `validated` on evidence it never saw.
    public init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(Ledger.self, from: data)
        } catch {
            throw SystemFailure.ledgerUnreadable(reason: "\(error)")
        }
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw SystemFailure.ledgerSchemaUnsupported(
                found    : schemaVersion,
                supported: Self.supportedSchemaVersion
            )
        }
    }

    /// The entry for a build, or `nil` when nobody has validated it.
    public func entry(for build: BuildIdentity) -> Entry? {
        builds[build.osVersion]
    }

    /// The verdict for one Facility on one entry, derived from the primitive
    /// rows. A requirement filed under a different `kind` than the Facility asks
    /// for counts as absent: the row describes something else.
    public func verdict(for facility: Facility, in entry: Entry) -> FacilityVerdict {
        var verdict = FacilityVerdict.validated
        for requirement in facility.requirements {
            guard let primitive = entry.primitives[requirement.ledgerKey],
                  primitive.kind == requirement.kind
            else {
                return .unvalidated
            }
            switch primitive.state {
            case .verified: continue
            case .limited:  verdict = .limited
            case .untested: return .unvalidated
            }
        }
        return verdict
    }
}
