//
//  SurfaceAttribution.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// HelperRelation is the shape of a verified link between a surface and the
/// assigned application, and it is two cases because a helper process is two
/// different things depending on who else uses it.
nonisolated package enum HelperRelation: Sendable, Equatable {

    /// The helper process exists for this application instance, so its surfaces
    /// are attributable as a whole.
    case dedicatedProcess

    /// The helper is a service several applications share. Exactly one surface
    /// is attributed, the one the relation names, and the rest of the process is
    /// left alone: taking a shared service whole would move another
    /// application's window.
    case sharedServiceSurface(windowNumber: Int)
}

/// AttributionDoubt is why a surface that might belong cannot be attributed. A
/// doubt is reported and never resolved by acting: an uncertain surface is not
/// moved, and its presence closes the input gate until the consumer settles it.
nonisolated package enum AttributionDoubt: String, Sendable, Equatable {

    /// The row carries no attested `WindowIdentity`, so there is no lifetime to
    /// compare against the assignment.
    case identityNotAttested

    /// A relation was claimed on evidence that cannot carry it, such as a PID or
    /// a window title.
    case relationNotVerifiable

    /// The process is a shared service with an attested relation for other
    /// surfaces, and this surface is not one of them.
    case sharedServiceSurfaceNotNamed
}

/// SurfaceAttribution is the answer for one surface: whose it is, as far as the
/// evidence goes.
nonisolated package enum SurfaceAttribution: Sendable, Equatable {

    /// A window of the assigned instance itself.
    case assignedInstance

    /// A surface of another process with a verified relation to the assignment.
    case helperSurface(HelperRelation)

    /// It might belong and the evidence does not say so. Never moved.
    case uncertain(AttributionDoubt)

    /// It belongs to somebody else. Not the seat's business at all.
    case unrelated

    /// True only for the two cases that may be taken into the seat.
    package var isAttributed: Bool {
        switch self {
            case .assignedInstance, .helperSurface: true
            case .uncertain, .unrelated:            false
        }
    }
}

/// HelperRelationClaim is a statement that one surface serves one assigned
/// instance, together with where that statement came from.
///
/// A claim is not a relation. `SurfaceAttributor` turns a claim into an
/// attribution only when its provenance can carry it, which is the difference
/// between a helper that was identified and a helper that was guessed at from a
/// name.
nonisolated package struct HelperRelationClaim: Sendable, Equatable {

    package let surface   : WindowIdentity
    package let serves    : ProcessIdentity
    package let relation  : HelperRelation
    package let provenance: EvidenceProvenance

    package init(
        surface   : WindowIdentity,
        serves    : ProcessIdentity,
        relation  : HelperRelation,
        provenance: EvidenceProvenance
    ) {
        self.surface    = surface
        self.serves     = serves
        self.relation   = relation
        self.provenance = provenance
    }
}

/// AttributedSurface is one row of a reading with its attribution attached.
nonisolated package struct AttributedSurface: Sendable, Equatable {

    package let surface    : WindowSurface
    package let attribution: SurfaceAttribution

    package init(surface: WindowSurface, attribution: SurfaceAttribution) {
        self.surface     = surface
        self.attribution = attribution
    }
}

/// SurfaceAttributor decides which surfaces of a reading belong to one assigned
/// application. It is a value built from the assignment and the helper relations
/// the consumer could attest, and it performs no reading of its own.
///
/// ## The rules, in the order they are applied
///
/// 1. A row with no attested identity, or one whose identity evidence is a PID
///    or a title, is `uncertain`: there is no lifetime to compare, and a PID
///    that matches is the reused-PID case.
/// 2. A row whose process lifetime is the assigned one is the application's own
///    window, whatever its level or title.
/// 3. A row named by an attested claim is attributed, as a dedicated helper
///    process or as the single surface of a shared service.
/// 4. A row of a process that has attested shared-service claims, and is not
///    named by one, is `uncertain`: it may be the assignment's and it may be
///    another consumer's, and moving it on a guess is how a seat takes a window
///    nobody offered it.
/// 5. Anything else is unrelated and is not touched.
nonisolated package struct SurfaceAttributor: Sendable {

    private let instance: ProcessIdentity

    /// Attested claims by the surface they name, and the processes those claims
    /// cover, precomputed so one pass over a reading stays linear.
    private var namedSurfaces      : [WindowIdentity: HelperRelation] = [:]
    private var dedicatedProcesses : Set<ProcessIdentity>             = []
    private var sharedProcesses    : Set<ProcessIdentity>             = []
    private var unqualifiedProcesses: Set<ProcessIdentity>            = []

    package init(instance: ProcessIdentity, claims: [HelperRelationClaim] = []) {
        self.instance = instance
        for claim in claims where claim.serves == instance {
            guard claim.provenance.quality.authorisesAttribution else {
                unqualifiedProcesses.insert(claim.surface.process)
                continue
            }
            namedSurfaces[claim.surface] = claim.relation
            switch claim.relation {
                case .dedicatedProcess:     dedicatedProcesses.insert(claim.surface.process)
                case .sharedServiceSurface: sharedProcesses.insert(claim.surface.process)
            }
        }
    }

    /// Attributes one surface, given the evidence its identity came from.
    ///
    /// `provenance` is about this row's identity and not about the list it came
    /// in: a row resolved only to a PID or matched by title cannot be attributed
    /// even when its numbers happen to agree with the assignment.
    package func attribution(
        of surface: WindowSurface,
        provenance: EvidenceProvenance = .windowServerAttestedIdentity
    ) -> SurfaceAttribution {

        guard provenance.quality.authorisesAttribution,
              let identity = surface.reference.identity
        else { return .uncertain(.identityNotAttested) }

        guard identity.process != instance else { return .assignedInstance }

        if let relation = namedSurfaces[identity] { return .helperSurface(relation) }
        if dedicatedProcesses.contains(identity.process) {
            return .helperSurface(.dedicatedProcess)
        }
        if sharedProcesses.contains(identity.process) {
            return .uncertain(.sharedServiceSurfaceNotNamed)
        }
        if unqualifiedProcesses.contains(identity.process) {
            return .uncertain(.relationNotVerifiable)
        }
        return .unrelated
    }

    /// Attributes a whole reading, keeping every row so that an uncertain
    /// surface is visible to the caller instead of being filtered away.
    package func attributed(_ reading: SurfaceInventoryReading) -> [AttributedSurface] {
        reading.rows.map {
            AttributedSurface(
                surface    : $0.surface,
                attribution: attribution(of: $0.surface, provenance: $0.provenance)
            )
        }
    }
}
