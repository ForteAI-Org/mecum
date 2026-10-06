//
//  CrossCheckedSurfaceReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import AppKit
import ApplicationServices
import Dispatch
import PrivateSymbols
import SeatCore
import WindowPlacement

/// The Accessibility facts read for one application window before they are
/// joined to an independently attested WindowServer row.
nonisolated package struct AccessibilitySurfaceRecord: Sendable, Equatable {

    package let processID   : Int32
    package let windowNumber: Int
    package let role        : SurfaceRole?
    package let isMinimised : Bool?
    package let isModal     : Bool?
    package let isMain      : Bool?
    package let isFocused   : Bool?
    package let parentWindowNumber: Int?
    package let appIsHidden : Bool

    package init(
        processID   : Int32,
        windowNumber: Int,
        role        : SurfaceRole?,
        isMinimised : Bool?,
        isModal     : Bool?,
        isMain      : Bool? = nil,
        isFocused   : Bool? = nil,
        parentWindowNumber: Int? = nil,
        appIsHidden : Bool
    ) {
        self.processID    = processID
        self.windowNumber = windowNumber
        self.role         = role
        self.isMinimised  = isMinimised
        self.isModal      = isModal
        self.isMain       = isMain
        self.isFocused    = isFocused
        self.parentWindowNumber = parentWindowNumber
        self.appIsHidden  = appIsHidden
    }
}

/// Why the complete native inventory could not be produced. The on-screen
/// fallback remains fail closed, but it retains this cause instead of reducing
/// every native failure to the same incomplete-list message.
nonisolated package enum CrossCheckedSurfaceReadFailure: Error, Sendable, Equatable,
    CustomStringConvertible {

    case accessibilityPermissionMissing
    case processUnavailable(processID: Int32)
    case passDeadlineExpired
    case attributeUnavailable(processID: Int32, attribute: String, error: Int32)
    case windowIdentityPrimitiveUnavailable(processID: Int32, index: Int)
    case windowIdentityReadFailed(processID: Int32, index: Int, error: Int32)
    case windowServerReadFailed(WindowServerProbe.SurfaceReadFailure)

    package var description: String {
        switch self {
            case .accessibilityPermissionMissing:
                "Accessibility permission is not available"
            case .processUnavailable(let processID):
                "The assigned process \(processID) is no longer running"
            case .passDeadlineExpired:
                "The native surface pass exhausted its 1250 ms deadline"
            case .attributeUnavailable(let processID, let attribute, let error):
                "Accessibility could not read \(attribute) for process \(processID) "
                    + "(AXError \(error))"
            case .windowIdentityPrimitiveUnavailable(let processID, let index):
                "The private primitive _AXUIElementGetWindow did not resolve, so accessibility "
                    + "entry \(index) for process \(processID) has no readable WindowServer "
                    + "identity"
            case .windowIdentityReadFailed(let processID, let index, let error):
                "Accessibility entry \(index) for process \(processID) refused its WindowServer "
                    + "identity read (AXError \(error))"
            case .windowServerReadFailed(let failure):
                failure.description
        }
    }
}

/// A required AX read gets one fast attempt and one recovery attempt only for
/// `.cannotComplete`. Both attempts consume one absolute deadline owned by the
/// complete native pass.
nonisolated package enum BoundedAccessibilityRead {

    package static let fastTimeout: Float = 0.1
    package static let recoveryTimeout: Float = 0.5
    package static let passNanoseconds: UInt64 = 1_250_000_000

    package struct Failure: Error, Sendable, Equatable {
        package let error   : AXError
        package let attempts: Int
    }

    package static func value<Value>(
        deadlineNanoseconds: UInt64,
        now                : () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        recoversCannotComplete: Bool = true,
        attempt            : (Float) -> (AXError, Value?)
    ) -> Result<Value, Failure> {

        guard let firstTimeout = timeout(
            noLongerThan: fastTimeout,
            deadlineNanoseconds: deadlineNanoseconds,
            now: now()
        ) else {
            return .failure(Failure(error: .cannotComplete, attempts: 0))
        }
        let first = attempt(firstTimeout)
        let firstCompletedAt = now()
        if first.0 == .success, let value = first.1 {
            guard firstCompletedAt <= deadlineNanoseconds else {
                return .failure(Failure(error: .cannotComplete, attempts: 0))
            }
            return .success(value)
        }
        guard recoversCannotComplete,
              first.0 == .cannotComplete,
              let secondTimeout = timeout(
                  noLongerThan: recoveryTimeout,
                  deadlineNanoseconds: deadlineNanoseconds,
                  now: firstCompletedAt
              )
        else {
            return .failure(Failure(error: first.0, attempts: 1))
        }

        let second = attempt(secondTimeout)
        guard second.0 == .success, let value = second.1 else {
            return .failure(Failure(error: second.0, attempts: 2))
        }
        guard now() <= deadlineNanoseconds else {
            return .failure(Failure(error: .cannotComplete, attempts: 0))
        }
        return .success(value)
    }

    private static func timeout(
        noLongerThan maximum: Float,
        deadlineNanoseconds: UInt64,
        now                : UInt64
    ) -> Float? {

        guard now < deadlineNanoseconds else { return nil }
        let remaining = Float(deadlineNanoseconds - now) / 1_000_000_000
        return max(0.001, min(maximum, remaining))
    }
}

/// Reads application windows through Accessibility and accepts a complete
/// inventory only when every AX window has a matching identity-attested
/// WindowServer row for the requested ID and the same process lifetime.
///
/// AX supplies the positive scope plus role, minimisation, modality, parentage
/// and the application's focused/main window. WindowServer supplies attested
/// identity, geometry and on-screen state for that scope. Its additional
/// same-process surfaces are not promoted into windows merely because their PID
/// matches. A missing AX counterpart or duplicate identifier marks the
/// inventory incomplete. A semantic AX attribute that cannot be read leaves its
/// role absent or its visibility uncertain, so selection still closes the input
/// gate without misreporting the membership pass.
///
/// ## What `AXWindows` scopes, and what it does not
///
/// `AXWindows` is an accessibility list and not a window server one, so an
/// entry in it can be an accessibility window that is no window server window
/// at all: Finder's desktop is one. An entry is **excluded** from the
/// application's scope on either of two positive readings, its AXRole read and
/// naming a role that is no window role, or `_AXUIElementGetWindow` succeeding
/// and answering a Window ID of zero. An excluded entry is removed from the
/// question, not answered: it never becomes a row, a claim, a member, a
/// candidate or a target, and it is never asked of the window server either,
/// because the pass asks only for the numbers the scope holds.
///
/// The role is read **before** the identity, and that order is the whole
/// point. Measured on 26A428, one read-only pass over every `AXWindows` entry
/// of every running application, 10 entries across 8 applications: 9 answered a
/// window and the tenth, Finder's desktop, answered AXRole `AXScrollArea` and
/// `illegalArgument` (-25201) for its identity. -25201 is also what an element
/// whose window was destroyed answers, and such an element fails AXRole too, as
/// `AccessibilityWindowNumberCache` and `AppWindowWatch` both record. So the
/// role is the one reading that tells a desktop from a dead window, and
/// excluding on the error code would instead let a destroyed window leave the
/// scope in silence.
///
/// A status item is outside all of this rather than covered by it. Measured on
/// the same build: the 8 applications carrying an `AXExtrasMenuBar` keep their
/// items under it, role `AXMenuBarItem` or `AXGroup`, and not one of those
/// elements appears in an `AXWindows` list. Were one to appear, its readable
/// non-window role would exclude it like any other.
///
/// Exclusion is not a relaxation of the completeness rule. Every window still
/// in scope must still have an identity-attested WindowServer counterpart, and
/// a missing counterpart still marks the inventory incomplete. What did change
/// is that a read which **failed** is no longer allowed to mean "not a window":
/// it fails the pass, with its own cause, exactly as it did before.
///
/// ## An ancestor the top level stops showing is kept, not buried
///
/// A modal stack is host, sheet, and whatever dialog the sheet opens next. When
/// the innermost dialog appears, the surface underneath it can leave both
/// `AXWindows` and the focused slot while the window server still attests it on
/// screen at the same identity. That absence used to make the pass inexact, the
/// member absent, and the seat suspended on a window nobody had closed:
/// measured as `retainedOnScreenWithoutAX=[37751:47781]` with Slack's open
/// panel and its Go to folder dialog.
///
/// Such a surface is kept as a row when a surface that **is** in the scope
/// names it as its own parent window, and the pass says so as
/// `RetainedSurfaceDisposition.obscuredByChild`. What keeps it is that positive
/// attestation and never the convenience: with nothing naming it, the surface
/// takes the withdrawal path exactly as before, and a time grace on its own
/// establishes nothing either way.
///
/// There is no budget on how many entries one pass may exclude. Each exclusion
/// is per-entry positive evidence rather than a heuristic, so ten of them are
/// ten facts and not a tenfold reason to doubt the pass, and a threshold would
/// be a guess with nothing behind it. An application whose whole `AXWindows`
/// list is excluded is therefore reported as an application with no windows,
/// which is a real and ordinary state here: Finder with no Finder window open
/// still carries its desktop entry, and the domain admits an Assigned
/// Application that has no windows at all.
nonisolated package enum CrossCheckedSurfaceReader {

    private struct SurfaceKey: Sendable, Hashable, Comparable {
        let processID   : Int32
        let windowNumber: Int

        static func < (lhs: SurfaceKey, rhs: SurfaceKey) -> Bool {
            lhs.processID == rhs.processID
                ? lhs.windowNumber < rhs.windowNumber
                : lhs.processID < rhs.processID
        }
    }

    /// The production pass. A failure names which native source could not be
    /// read; the caller retains the established on-screen, incomplete fallback
    /// rather than treating a read failure as no windows.
    package static func snapshot(
        ownedBy processIDs: Set<Int32>,
        retaining retainedIdentities: Set<WindowIdentity> = [],
        windowNumbers: AccessibilityWindowNumberCache
    ) -> Result<AssignedSurfaceSnapshot, CrossCheckedSurfaceReadFailure> {

        guard Permissions.preflight(.accessibility) else {
            return .failure(.accessibilityPermissionMissing)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ BoundedAccessibilityRead.passNanoseconds
        let accessibility: [AccessibilitySurfaceRecord]
        switch accessibilityRecords(
            ownedBy: processIDs,
            deadlineNanoseconds: deadline,
            windowNumbers: windowNumbers
        ) {
            case .success(let records): accessibility = records
            case .failure(let failure): return .failure(failure)
        }

        var requested = Dictionary(grouping: accessibility, by: \.processID).mapValues {
            Set($0.map(\.windowNumber))
        }
        let retained = retainedIdentities.filter { processIDs.contains($0.processID) }
        for identity in retained {
            requested[identity.processID, default: []].insert(identity.windowNumber)
        }
        let serverSurfaces: [WindowSurface]
        switch WindowServerProbe.surfaceReading(matching: requested) {
            case .success(let surfaces): serverSurfaces = surfaces
            case .failure(let failure): return .failure(.windowServerReadFailed(failure))
        }

        return .success(assemble(
            windowServer: serverSurfaces,
            accessibility: accessibility,
            retaining: retained,
            observedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
    }

    /// The pure join behind the native pass, exposed package-wide so the Unit
    /// tier can prove the fail-closed set and claim construction without TCC.
    package static func assemble(
        windowServer : [WindowSurface],
        accessibility: [AccessibilitySurfaceRecord],
        retaining retainedIdentities: Set<WindowIdentity> = [],
        observedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AssignedSurfaceSnapshot {

        var serverByKey: [SurfaceKey: WindowSurface] = [:]
        var serverDuplicates: Set<SurfaceKey> = []
        for surface in windowServer {
            let key = SurfaceKey(
                processID   : surface.reference.processID,
                windowNumber: surface.reference.windowNumber
            )
            if serverByKey.updateValue(surface, forKey: key) != nil {
                serverDuplicates.insert(key)
            }
        }

        var axByKey: [SurfaceKey: AccessibilitySurfaceRecord] = [:]
        var axDuplicates: Set<SurfaceKey> = []
        for record in accessibility {
            let key = SurfaceKey(processID: record.processID, windowNumber: record.windowNumber)
            if axByKey.updateValue(record, forKey: key) != nil {
                axDuplicates.insert(key)
            }
        }

        var retainedByKey: [SurfaceKey: WindowIdentity] = [:]
        var retainedDuplicates: Set<SurfaceKey> = []
        for identity in retainedIdentities {
            let key = SurfaceKey(
                processID   : identity.processID,
                windowNumber: identity.windowNumber
            )
            if retainedByKey.updateValue(identity, forKey: key) != nil {
                retainedDuplicates.insert(key)
            }
        }

        let serverKeys = Set(serverByKey.keys)
        let axKeys     = Set(axByKey.keys)
        let matched    = serverKeys.intersection(axKeys).sorted()

        var identitiesByKey: [SurfaceKey: WindowIdentity] = [:]
        for key in matched {
            identitiesByKey[key] = serverByKey[key]?.reference.identity
        }

        /// The first surface still inside the scope that names this key as its
        /// own parent window, with the identity both sources attested for it.
        ///
        /// It is the whole of what keeps an ancestor: a relation this pass read
        /// off a surface it can see, never one inferred from the ancestor being
        /// convenient. A child whose own identity nothing attested cannot
        /// attest anybody else's parentage either.
        func attestingChild(of key: SurfaceKey) -> WindowIdentity? {
            matched
                .lazy
                .filter {
                    $0.processID == key.processID
                        && axByKey[$0]?.parentWindowNumber == key.windowNumber
                }
                .compactMap { identitiesByKey[$0] }
                .first
        }

        // Every retained surface outside the application's own scope, answered
        // one by one. A duplicate on either side is left unanswered: it already
        // disqualifies the pass on its own terms and nothing can be read off it.
        var dispositions: [SurfaceKey: RetainedSurfaceDisposition] = [:]
        var retainedOffScreen: Set<SurfaceKey> = []
        var obscured: Set<SurfaceKey> = []
        for key in Set(retainedByKey.keys).subtracting(axKeys) {
            guard !retainedDuplicates.contains(key), !serverDuplicates.contains(key),
                  let expected = retainedByKey[key]
            else { continue }

            // Named in this pass's own window server request and answered with
            // no row: destroyed, the one absence that is positive evidence.
            guard let surface = serverByKey[key] else {
                dispositions[key] = .destroyed
                continue
            }
            guard surface.reference.identity == expected else {
                dispositions[key] = .unrelated
                continue
            }
            guard surface.isVisible else {
                retainedOffScreen.insert(key)
                continue
            }
            guard let child = attestingChild(of: key) else {
                dispositions[key] = .withdrawn
                continue
            }
            dispositions[key] = .obscuredByChild(child)
            obscured.insert(key)
        }

        // An ancestor kept this way is one of the pass's identities: without it
        // the child's parentage claim would find no parent and be published as
        // an application-wide modal, which blocks every window of the
        // application including the host the person is working in.
        for key in retainedOffScreen.union(obscured) {
            identitiesByKey[key] = serverByKey[key]?.reference.identity
        }

        let unexplainedOnScreen = Set(dispositions.keys.filter { dispositions[$0] == .withdrawn })
        let isExact = axKeys.isSubset(of: serverKeys)
            && serverDuplicates.isDisjoint(with: axKeys)
            && axDuplicates.isEmpty
            && retainedDuplicates.isEmpty
            && unexplainedOnScreen.isEmpty

        var rows   : [SurfaceInventoryReading.Row] = []
        var claims = SelectionClaimBatch()
        for key in matched {
            guard let surface = serverByKey[key],
                  let record = axByKey[key],
                  let identity = surface.reference.identity
            else { continue }

            rows.append(
                SurfaceInventoryReading.Row(
                    surface   : surface,
                    provenance: .windowServerAttestedIdentity
                )
            )

            if let role = record.role {
                claims.roles.append(
                    SurfaceRoleClaim(
                        surface   : identity,
                        role      : Self.role(of: record, readAs: role, frame: surface.reference.frame),
                        provenance: .qualifiedRoleAttestation
                    )
                )
            }

            claims.visibilities.append(
                SurfaceVisibilityClaim(
                    surface   : identity,
                    state     : visibility(of: record, serverSurface: surface),
                    provenance: .qualifiedVisibilityAttestation
                )
            )

            let parentKey = record.parentWindowNumber.map {
                SurfaceKey(processID: record.processID, windowNumber: $0)
            }
            let parent = parentKey.flatMap { identitiesByKey[$0] }

            if let parent, parent != identity {
                claims.parents.append(
                    SurfaceParentClaim(
                        child     : identity,
                        parent    : parent,
                        provenance: .qualifiedParentAttestation
                    )
                )
            }

            if record.isModal == true || Self.runsModally(record, level: surface.level) {
                claims.modals.append(
                    ModalRelationClaim(
                        modal     : identity,
                        scope     : parent.map(ModalScope.window) ?? .application,
                        provenance: .qualifiedModalAttestation
                    )
                )
            }
        }

        // An ancestor the top accessibility level no longer shows stays a row,
        // at the frame and identity the window server attests for it. It
        // carries no claim of its own: accessibility said nothing about it this
        // pass, and the role, visibility and modal scope already attested for
        // it stand until something positive replaces them. Dropping the row
        // instead is what made the surface absent, spent its containment budget
        // and suspended the seat on a window that was on screen all along.
        for key in obscured.sorted() {
            guard let surface = serverByKey[key] else { continue }
            rows.append(
                SurfaceInventoryReading.Row(
                    surface   : surface,
                    provenance: .windowServerAttestedIdentity
                )
            )
        }

        for key in retainedOffScreen.sorted() {
            guard let surface = serverByKey[key],
                  let identity = surface.reference.identity
            else { continue }

            rows.append(
                SurfaceInventoryReading.Row(
                    surface     : surface,
                    provenance  : .windowServerAttestedIdentity,
                    isOrderedOut: true
                )
            )
            claims.visibilities.append(
                SurfaceVisibilityClaim(
                    surface   : identity,
                    state     : .withdrawnEstablished,
                    provenance: .qualifiedVisibilityAttestation
                )
            )
        }
        rows.sort {
            ($0.surface.reference.processID, $0.surface.reference.windowNumber)
                < ($1.surface.reference.processID, $1.surface.reference.windowNumber)
        }

        let visibleRecords = accessibility.filter { record in
            let key = SurfaceKey(
                processID   : record.processID,
                windowNumber: record.windowNumber
            )
            guard let surface = serverByKey[key] else { return false }
            return visibility(of: record, serverSurface: surface) == .visibleInteractive
        }
        if isExact, let current = currentApplicationTarget(in: visibleRecords),
           let identity = identitiesByKey[
               SurfaceKey(processID: current.processID, windowNumber: current.windowNumber)
           ] {
            claims.recency.append(
                RecencyClaim(
                    surface              : identity,
                    signal               : .returnedToFront,
                    provenance           : .qualifiedFrontOrderAttestation,
                    origin               : .application(provenance: .qualifiedRaiseAttribution),
                    observedAtNanoseconds: observedAtNanoseconds
                )
            )
        }

        let completeness: InventoryCompleteness = isExact
            ? .complete(provenance: .qualifiedSurfaceEnumeration)
            : .incomplete(reason: mismatchReason(
                accessibilityOnly: axKeys.subtracting(serverKeys),
                serverDuplicates: serverDuplicates.intersection(axKeys),
                axDuplicates    : axDuplicates,
                retainedDuplicates: retainedDuplicates,
                retainedOnScreenWithoutAX: unexplainedOnScreen
            ))

        // Reported, not acted on, except for the destruction: how long a
        // surface has been outside the application's own scope is not something
        // one pass can know, and a destroyed window no later reading brings
        // back needs no wait at all.
        var retained: [WindowIdentity: RetainedSurfaceDisposition] = [:]
        for (key, disposition) in dispositions {
            guard let identity = retainedByKey[key] else { continue }
            retained[identity] = disposition
        }

        return AssignedSurfaceSnapshot(
            inventory: SurfaceInventoryReading(rows: rows, completeness: completeness),
            claims   : claims,
            retained : retained
        )
    }

    private static func accessibilityRecords(
        ownedBy processIDs : Set<Int32>,
        deadlineNanoseconds: UInt64,
        windowNumbers      : AccessibilityWindowNumberCache
    ) -> Result<[AccessibilitySurfaceRecord], CrossCheckedSurfaceReadFailure> {

        // Whatever this pass resolved becomes the whole cache, on the way out
        // of a complete pass and of one that gave up partway alike.
        defer { windowNumbers.endPass() }

        var records: [AccessibilitySurfaceRecord] = []
        for processID in processIDs.sorted() {
            guard let running = NSRunningApplication(processIdentifier: processID),
                  !running.isTerminated
            else { return .failure(.processUnavailable(processID: processID)) }

            let application = AXUIElementCreateApplication(processID)
            let windows: [AXUIElement]
            switch requiredAttribute(
                application,
                name: kAXWindowsAttribute,
                processID: processID,
                deadlineNanoseconds: deadlineNanoseconds
            ) as Result<[AXUIElement], CrossCheckedSurfaceReadFailure> {
                case .success(let value): windows = value
                case .failure(let failure): return .failure(failure)
            }

            AXUIElementSetMessagingTimeout(application, BoundedAccessibilityRead.fastTimeout)
            let applicationSlots = (try? multipleAttributes(
                application,
                names: applicationWindowAttributes,
                deadlineNanoseconds: deadlineNanoseconds,
                recoversCannotComplete: false
            ).get()) ?? [:]
            let mainWindowNumber = relatedElement(applicationSlots[kAXMainWindowAttribute])
                .flatMap {
                    windowNumber(
                        of: $0,
                        ownedBy: processID,
                        deadlineNanoseconds: deadlineNanoseconds,
                        windowNumbers: windowNumbers
                    )
                }
            let focusedElement = relatedElement(applicationSlots[kAXFocusedWindowAttribute])
            let focusedWindowNumber = focusedElement
                .flatMap {
                    windowNumber(
                        of: $0,
                        ownedBy: processID,
                        deadlineNanoseconds: deadlineNanoseconds,
                        windowNumbers: windowNumbers
                    )
                }

            /// One entry read into a record, or nothing when the entry is no
            /// window of this application. Both the enumeration and the focused
            /// slot go through it so a surface cannot mean two different things
            /// depending on which slot it was reached by.
            func record(
                for element: AXUIElement,
                index      : Int
            ) -> Result<AccessibilitySurfaceRecord?, CrossCheckedSurfaceReadFailure> {

                let facts: WindowFacts?
                switch windowFacts(
                    element,
                    processID: processID,
                    index: index,
                    deadlineNanoseconds: deadlineNanoseconds,
                    windowNumbers: windowNumbers
                ) {
                    case .success(let value): facts = value
                    case .failure(let failure): return .failure(failure)
                }
                // Not a window server window at all, so not a window of this
                // application: out of the scope, and the reading carries on.
                guard let facts else { return .success(nil) }
                return .success(
                    AccessibilitySurfaceRecord(
                        processID   : processID,
                        windowNumber: facts.windowNumber,
                        role        : facts.role,
                        isMinimised : facts.isMinimised,
                        isModal     : facts.isModal,
                        isMain      : mainWindowNumber.map { $0 == facts.windowNumber },
                        isFocused   : focusedWindowNumber.map { $0 == facts.windowNumber },
                        parentWindowNumber: facts.isModal == true ? parentWindowNumber(
                            of: element,
                            ownedBy: processID,
                            excluding: facts.windowNumber,
                            deadlineNanoseconds: deadlineNanoseconds,
                            windowNumbers: windowNumbers
                        ) : nil,
                        appIsHidden : running.isHidden
                    )
                )
            }

            for (index, window) in windows.enumerated() {
                switch record(for: window, index: index) {
                    case .success(let value): value.map { records.append($0) }
                    case .failure(let failure): return .failure(failure)
                }
            }

            // The focused window is not always one of the enumerated ones. An
            // application hosting an open and save panel puts the panel up as an
            // `AXSheet` that `AXWindows` does not list, and the focused slot is
            // the only way to it: measured on 26A5425a with Slack's attach panel,
            // where `AXWindows` held the standard window alone and the focused
            // slot held the sheet at the panel's own rect. A surface that never
            // becomes a row never becomes a member, so the seat saw the window
            // server's surface for it and could never attribute it.
            //
            // It is added and not substituted, and it is read through the same
            // scope rules as any entry: a focused element that is no window of
            // this application is excluded exactly as an enumerated one is.
            if let focusedElement, let focusedWindowNumber,
               !records.contains(where: {
                   $0.processID == processID && $0.windowNumber == focusedWindowNumber
               }) {
                switch record(for: focusedElement, index: windows.count) {
                    case .success(let value): value.map { records.append($0) }
                    case .failure(let failure): return .failure(failure)
                }
            }
        }
        guard DispatchTime.now().uptimeNanoseconds <= deadlineNanoseconds else {
            return .failure(.passDeadlineExpired)
        }
        return .success(records)
    }

    private struct WindowFacts {
        let windowNumber: Int
        let role        : SurfaceRole?
        let isMinimised : Bool?
        let isModal     : Bool?
    }

    /// Which reading took one `AXWindows` entry out of the application's
    /// scope. Both are answers the entry gave about itself rather than an
    /// inference from an error code, and they are kept apart because they come
    /// from two different reads at two different points of the pass.
    nonisolated package enum NonWindowEvidence: Sendable, Equatable {

        /// AXRole was read and names a role no window carries. Measured on
        /// 26A428: Finder's desktop entry, `AXScrollArea`.
        case role(String)

        /// `_AXUIElementGetWindow` succeeded and answered a Window ID of zero.
        case identityIsZero
    }

    /// Why one `AXWindows` entry produced no window number, as the two opposite
    /// things that can mean.
    nonisolated package enum SurfaceScopeRefusal: Error, Sendable, Equatable {

        /// The entry positively answered that it is no window, and says on
        /// which evidence. It leaves the application's scope and the rest of
        /// the reading goes on.
        case notAWindow(NonWindowEvidence)

        /// The entry could not be read. The pass fails with this cause.
        case unreadable(CrossCheckedSurfaceReadFailure)
    }

    /// The three AXRole values an `AXWindows` entry can carry and stay in the
    /// application's scope: exactly the roles
    /// `role(named:subrole:positionIsSettable:actions:childCount:)` can answer
    /// for, so an entry outside this set could never have carried a role anyway.
    private static let windowRoles: Set<String> = [
        kAXWindowRole as String,
        kAXSheetRole  as String,
        kAXDrawerRole as String
    ]

    /// The AXSubrole values only a window carries, which keep an entry in the
    /// application's scope as an `AXWindow` whatever role it reads.
    private static let windowSubroles: Set<String> = [
        kAXStandardWindowSubrole       as String,
        kAXDialogSubrole               as String,
        kAXSystemDialogSubrole         as String,
        kAXFloatingWindowSubrole       as String,
        kAXSystemFloatingWindowSubrole as String
    ]

    /// What one entry's AXRole slot means for the application's scope: the role
    /// name for an entry the scope keeps, an exclusion for a role that is read
    /// and is no window role, and a failed pass for a role that cannot be read.
    ///
    /// It is a pure function of the slot for the same reason `scopeOutcome` is
    /// a pure function of its reading: the Unit tier can then prove all three
    /// outcomes without TCC and without a live window. The exclusion and the
    /// failure sit on opposite sides of one measurement, 26A428: Finder's
    /// desktop reads `AXScrollArea` and is no window, while an element whose
    /// window was destroyed fails AXRole outright. Reading the role first is
    /// what keeps the two apart, because both answer -25201 for their identity.
    ///
    /// A window subrole answers for a role the application renamed. Photoshop's
    /// New Document, measured on 30/09/2026, is an `AXWindows` entry that reads
    /// `AXLayoutArea` with subrole `AXDialog`, `AXModal` true, a close button
    /// and a window server row at level 8: excluded on its role, it made no
    /// modal claim, and the seat kept the blocked Home window as the scene.
    package static func roleScopeOutcome(
        of slot  : CFTypeRef?,
        subrole  : CFTypeRef? = nil,
        processID: Int32
    ) -> Result<String, SurfaceScopeRefusal> {

        let roleName: String
        switch requiredSlot(
            slot,
            processID: processID,
            attribute: kAXRoleAttribute
        ) as Result<String, CrossCheckedSurfaceReadFailure> {
            case .success(let value): roleName = value
            case .failure(let failure): return .failure(.unreadable(failure))
        }
        if windowRoles.contains(roleName) { return .success(roleName) }
        guard let named = subrole as? String, windowSubroles.contains(named) else {
            return .failure(.notAWindow(.role(roleName)))
        }
        return .success(kAXWindowRole as String)
    }

    /// What one identity reading means for the application's scope.
    ///
    /// It is a pure function of the reading so that the Unit tier can prove
    /// every outcome without TCC and without a live window, which the read
    /// itself cannot offer. `.noWindow` is the only outcome that narrows the
    /// scope, and it narrows it by removing the entry rather than answering
    /// for it. Every other non-number outcome fails the whole pass and now
    /// says which one it was: treating "I could not read this" as "this is not
    /// a window" is the collapse this separation exists to remove, and doing it
    /// in that direction would be worse than the bug it came from.
    package static func scopeOutcome(
        of reading: Result<WindowRelocator.WindowNumberReading, BoundedAccessibilityRead.Failure>,
        processID : Int32,
        index     : Int
    ) -> Result<Int, SurfaceScopeRefusal> {

        func unreadable(
            _ failure: CrossCheckedSurfaceReadFailure
        ) -> Result<Int, SurfaceScopeRefusal> {
            .failure(.unreadable(failure))
        }

        switch reading {
            case .success(.number(let windowNumber)):
                return .success(windowNumber)

            case .success(.noWindow):
                return .failure(.notAWindow(.identityIsZero))

            case .success(.symbolUnavailable):
                return unreadable(.windowIdentityPrimitiveUnavailable(
                    processID: processID,
                    index    : index
                ))

            case .success(.readFailed(let error)):
                return unreadable(.windowIdentityReadFailed(
                    processID: processID,
                    index    : index,
                    error    : error.rawValue
                ))

            case .failure(let failure):
                // Zero attempts is the bounded read's own deadline and not an
                // AXError any element produced, so it keeps the deadline case.
                guard failure.attempts > 0 else { return unreadable(.passDeadlineExpired) }
                return unreadable(.windowIdentityReadFailed(
                    processID: processID,
                    index    : index,
                    error    : failure.error.rawValue
                ))
        }
    }

    /// The window attributes one batched read collects. AXRole is required, and
    /// AXSubrole is required only once AXRole says AXWindow; it rides along for
    /// every window because one more slot in the same round trip costs nothing,
    /// and its slot is simply left unread for a sheet or a drawer. AXMinimized
    /// and AXModal are optional: an unreadable slot leaves the field nil.
    private static let windowAttributes = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXMinimizedAttribute,
        kAXModalAttribute
    ]

    /// The application attributes one batched read collects, both optional and
    /// both resolved further by a window number read on the element that comes
    /// back. AXWindows is deliberately not among them: it is required and it
    /// recovers from `.cannotComplete`, which is the other retry contract.
    private static let applicationWindowAttributes = [
        kAXMainWindowAttribute,
        kAXFocusedWindowAttribute
    ]

    /// The facts of one `AXWindows` entry, or `nil` for an entry that is not a
    /// window and therefore leaves the application's scope.
    private static func windowFacts(
        _ window            : AXUIElement,
        processID           : Int32,
        index               : Int,
        deadlineNanoseconds : UInt64,
        windowNumbers       : AccessibilityWindowNumberCache
    ) -> Result<WindowFacts?, CrossCheckedSurfaceReadFailure> {

        // A batch that fails as a whole is AXRole failing, the first required
        // attribute it carries, and it fails the pass as that single read did.
        let slots: [String: CFTypeRef]
        switch nativeResult(
            multipleAttributes(
                window,
                names: windowAttributes,
                deadlineNanoseconds: deadlineNanoseconds
            ),
            processID: processID,
            attribute: kAXRoleAttribute
        ) {
            case .success(let value): slots = value
            case .failure(let failure): return .failure(failure)
        }

        // The role decides before the identity is asked for, and this is the
        // same batched read as before rather than one more round trip.
        let roleName: String
        switch roleScopeOutcome(
            of       : slots[kAXRoleAttribute],
            subrole  : slots[kAXSubroleAttribute],
            processID: processID
        ) {
            case .success(let value): roleName = value
            case .failure(.notAWindow): return .success(nil)
            case .failure(.unreadable(let failure)): return .failure(failure)
        }

        let identity: Result<Int, SurfaceScopeRefusal> =
            windowNumbers.windowNumber(of: window, ownedBy: processID) {
                scopeOutcome(
                    of: BoundedAccessibilityRead.value(
                        deadlineNanoseconds: deadlineNanoseconds
                    ) { timeout in
                        AXUIElementSetMessagingTimeout(window, timeout)
                        // Only a call that failed is worth a second attempt. No
                        // window and an unresolved symbol are answers already.
                        let reading = WindowRelocator.windowNumberReading(of: window)
                        guard case .readFailed(let error) = reading else {
                            return (.success, reading)
                        }
                        return (error, nil)
                    },
                    processID: processID,
                    index    : index
                )
            }
        let windowNumber: Int
        switch identity {
            case .success(let value): windowNumber = value
            // Excluded, and deliberately not remembered: the cache stores
            // numbers only, so every pass asks this entry again for itself.
            case .failure(.notAWindow): return .success(nil)
            case .failure(.unreadable(let failure)): return .failure(failure)
        }
        let isMinimised = optionalBool(slots[kAXMinimizedAttribute])
        let isModal     = modality(of: slots[kAXModalAttribute], roleName: roleName)
        // An unreadable count is this window's own answer and never the
        // application's. Failing the pass on it would take every window of the
        // application out of the inventory over one attribute of one of them,
        // and leave the seat unable to observe an application that is working:
        // this reading simply cannot say what this surface is, so it says
        // nothing about it and the rest of the pass stands. A spent deadline is
        // the exception, because that is a fact about the pass.
        let children: Int?
        switch childCount(
            of: window,
            processID: processID,
            deadlineNanoseconds: deadlineNanoseconds
        ) {
            case .success(let value):             children = value
            case .failure(.passDeadlineExpired):  return .failure(.passDeadlineExpired)
            case .failure:                        children = nil
        }

        func facts(_ role: SurfaceRole?) -> Result<WindowFacts?, CrossCheckedSurfaceReadFailure> {
            .success(WindowFacts(
                windowNumber: windowNumber,
                role        : role,
                isMinimised : isMinimised,
                isModal     : isModal
            ))
        }

        // A sheet and a drawer answer without a subrole, and they answer here
        // rather than inline so every role passes the same emptiness rule.
        if roleName == (kAXSheetRole as String) || roleName == (kAXDrawerRole as String) {
            return facts(role(
                named: roleName,
                subrole: nil,
                positionIsSettable: false,
                actions: [],
                childCount: children,
                isModal: isModal
            ))
        }

        let subrole: String
        switch requiredSlot(
            slots[kAXSubroleAttribute],
            processID: processID,
            attribute: kAXSubroleAttribute
        ) as Result<String, CrossCheckedSurfaceReadFailure> {
            case .success(let value): subrole = value
            case .failure(let failure): return .failure(failure)
        }
        let knownRole = role(
            named: roleName,
            subrole: subrole,
            positionIsSettable: false,
            actions: [],
            childCount: children,
            isModal: isModal
        )
        if let knownRole { return facts(knownRole) }
        guard subrole == "AXUnknown" else { return facts(nil) }

        let movable: Bool
        switch positionIsSettable(
            window,
            processID: processID,
            deadlineNanoseconds: deadlineNanoseconds
        ) {
            case .success(let value): movable = value
            case .failure(let failure): return .failure(failure)
        }
        let actions: Set<String>
        switch actionNames(
            of: window,
            processID: processID,
            deadlineNanoseconds: deadlineNanoseconds
        ) {
            case .success(let value): actions = value
            case .failure(let failure): return .failure(failure)
        }
        return facts(role(
            named: roleName,
            subrole: subrole,
            positionIsSettable: movable,
            actions: actions,
            childCount: children,
            isModal: isModal
        ))
    }

    /// What one window's readable traits say it is, as the single question
    /// behind all of them: is this a window a person operates. A role is the
    /// answer to that question and not a transcription of the subrole, which is
    /// why the traits decide and the name alone never does.
    ///
    /// **A window with no children is nobody's window.** An empty surface is a
    /// surface nobody operates, and the rule holds for every role this function
    /// can answer rather than for AXDialog alone: a rule that applied to one
    /// subrole and not its neighbours is a rule nobody can reason about later.
    /// No size threshold is involved and none would help, because a small
    /// utility panel with controls in it is a legitimate target.
    ///
    /// **The rule is sound and it was not sufficient**, and the surface it was
    /// written for is what proved that. It is the traffic light overlay macOS
    /// draws over every window it raises: AXWindow, subrole AXDialog, title
    /// "Window", 66 by 20 points, position settable, AXRaise supported, a new
    /// Window ID every time and destroyed within seconds. It is born with zero
    /// accessibility children and **gains one within 18 ms**, measured twice,
    /// so a fold a moment later reads it as a dialog, claims that role, and a
    /// claimed role is never withdrawn. Nothing readable separates it from a
    /// save panel, which is an AXDialog with children too, so no rule that can
    /// be written here settles it. That is why the seat no longer moves its
    /// operating target for a window it detected: this reader narrows what may
    /// be selected, and deciding what is driven is not its job.
    ///
    /// **An unknown subrole needs the two operability traits**, a writable
    /// position and raise, which admits DaVinci's main window without turning
    /// every unknown AX surface into a document.
    ///
    /// `childCount` is `nil` for a count the reading could not take, which is
    /// not zero and is not an empty window: it is a window this pass cannot say
    /// anything about, and it answers no role for the same reason an empty one
    /// does: nothing here may be targeted on a trait nobody read. The two are
    /// kept apart in the type and not collapsed into a zero, because everywhere
    /// else in this kit an unread fact is its own answer.
    ///
    /// No answer here is forever, and none is withdrawn either. A window still
    /// building its interface reads no children for a moment, so the reader
    /// emits no role claim for it and the nucleus holds it as `roleNotRead`
    /// until a later fold reads it with children. A role once claimed is never
    /// taken back: `SeatTargetSelectionKit.declareRole` is only ever called
    /// with a role the reader produced, so nothing may be built on a withdrawal
    /// that does not exist.
    ///
    /// **A modal window answers for its own emptiness.** Its modal claim is
    /// made whatever its role, and it blocks every other window of the
    /// application, so a modal with no role leaves nothing eligible at all.
    /// Photoshop's New Document, measured on 30/09/2026, draws its whole
    /// interface in a view accessibility reads no child of, for as long as it
    /// is open.
    package static func role(
        named role        : String,
        subrole           : String?,
        positionIsSettable: Bool,
        actions           : Set<String>,
        childCount        : Int?,
        isModal           : Bool? = nil
    ) -> SurfaceRole? {

        guard isModal == true || (childCount ?? 0) > 0 else { return nil }
        if role == (kAXSheetRole as String) { return .dialog }
        if role == (kAXDrawerRole as String) { return .interactivePanel }
        guard role == (kAXWindowRole as String), let subrole else { return nil }
        if subrole == (kAXStandardWindowSubrole as String) { return .document }
        if subrole == (kAXDialogSubrole as String)
            || subrole == (kAXSystemDialogSubrole as String) { return .dialog }
        if subrole == (kAXFloatingWindowSubrole as String)
            || subrole == (kAXSystemFloatingWindowSubrole as String) { return .interactivePanel }
        if subrole == "AXUnknown", positionIsSettable,
           actions.contains(kAXRaiseAction as String) { return .interactivePanel }
        return nil
    }

    /// Whether AX will accept a write to this window's AXPosition, which is the
    /// first of the two traits an unknown subrole has to show.
    ///
    /// It is deliberately read on every pass and never cached. Settability is a
    /// state of the window and not a property of it: a window that enters full
    /// screen stops accepting a position, and an application is free to clear
    /// and restore `isMovable` on a window it keeps. A remembered answer would
    /// keep admitting a window that can no longer be placed, or keep refusing
    /// one that can, and the element and Window ID would not have changed to
    /// say so. The same holds for the action list read beside it.
    private static func positionIsSettable(
        _ window           : AXUIElement,
        processID          : Int32,
        deadlineNanoseconds: UInt64
    ) -> Result<Bool, CrossCheckedSurfaceReadFailure> {

        let result: Result<Bool, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(deadlineNanoseconds: deadlineNanoseconds) { timeout in
                AXUIElementSetMessagingTimeout(window, timeout)
                var isSettable = DarwinBoolean(false)
                let error = AXUIElementIsAttributeSettable(
                    window,
                    kAXPositionAttribute as CFString,
                    &isSettable
                )
                return (error, error == .success ? isSettable.boolValue : nil)
            }
        return nativeResult(result, processID: processID, attribute: "AXPosition/settable")
    }

    private static func actionNames(
        of window          : AXUIElement,
        processID          : Int32,
        deadlineNanoseconds: UInt64
    ) -> Result<Set<String>, CrossCheckedSurfaceReadFailure> {

        let result: Result<Set<String>, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(deadlineNanoseconds: deadlineNanoseconds) { timeout in
                AXUIElementSetMessagingTimeout(window, timeout)
                var raw: CFArray?
                let error = AXUIElementCopyActionNames(window, &raw)
                return (error, (raw as? [String]).map(Set.init))
            }
        return nativeResult(result, processID: processID, attribute: "AXActions")
    }

    /// How many accessibility children the window has, read as a count rather
    /// than by copying AXChildren: one round trip, no array to marshal, and the
    /// count is the whole of what the emptiness rule asks for.
    ///
    /// It is required like AXRole and unlike AXMinimized. A count that could
    /// not be read fails the pass with its cause instead of arriving as zero,
    /// because a silent zero would refuse every window of an application whose
    /// accessibility is slow, which is the opposite of the rule's purpose.
    private static func childCount(
        of window          : AXUIElement,
        processID          : Int32,
        deadlineNanoseconds: UInt64
    ) -> Result<Int, CrossCheckedSurfaceReadFailure> {

        let result: Result<Int, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(deadlineNanoseconds: deadlineNanoseconds) { timeout in
                AXUIElementSetMessagingTimeout(window, timeout)
                var count: CFIndex = 0
                let error = AXUIElementGetAttributeValueCount(
                    window,
                    kAXChildrenAttribute as CFString,
                    &count
                )
                return (error, error == .success ? Int(count) : nil)
            }
        return nativeResult(result, processID: processID, attribute: "AXChildren/count")
    }

    private static func requiredAttribute<Value>(
        _ element           : AXUIElement,
        name                : String,
        processID           : Int32,
        deadlineNanoseconds : UInt64
    ) -> Result<Value, CrossCheckedSurfaceReadFailure> {

        let result: Result<Value, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(deadlineNanoseconds: deadlineNanoseconds) { timeout in
                AXUIElementSetMessagingTimeout(element, timeout)
                var raw: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
                return (error, raw as? Value)
            }
        return nativeResult(result, processID: processID, attribute: name)
    }

    /// Reads several attributes of one element in a single AX round trip, which
    /// is what the per-window pass costs instead of one trip per attribute.
    /// `.stopOnError` is deliberately not passed: without it the call answers
    /// every attribute and returns an AXValue of type kAXValueAXErrorType in the
    /// slot of each one it could not read, and that per-slot error is what lets
    /// one call serve the required and the optional attributes together. A
    /// non-success AXError from the call itself is the whole-call failure and
    /// stays one attempt of the bounded read, deadline included.
    private static func multipleAttributes(
        _ element             : AXUIElement,
        names                 : [String],
        deadlineNanoseconds   : UInt64,
        recoversCannotComplete: Bool = true
    ) -> Result<[String: CFTypeRef], BoundedAccessibilityRead.Failure> {

        BoundedAccessibilityRead.value(
            deadlineNanoseconds: deadlineNanoseconds,
            recoversCannotComplete: recoversCannotComplete
        ) { timeout in
            AXUIElementSetMessagingTimeout(element, timeout)
            var raw: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(
                element,
                names as CFArray,
                AXCopyMultipleAttributeOptions(),
                &raw
            )
            // A values array that is not positional is not decodable, so it
            // fails closed rather than being matched up by guesswork.
            guard let values = raw as? [CFTypeRef], values.count == names.count else {
                return (error, nil)
            }
            return (error, Dictionary(zip(names, values), uniquingKeysWith: { first, _ in first }))
        }
    }

    /// The AXError a batched slot carries in place of a value, or nil when the
    /// slot holds a value. Verified against the HIServices contract for
    /// `AXUIElementCopyMultipleAttributeValues` with no options: an unreadable
    /// attribute arrives as an AXValue of type kAXValueAXErrorType, or as
    /// kCFNull, at its own position. kCFNull carries no code, so it stays a
    /// value here and the caller's own type check rejects it, exactly as a
    /// single read whose value was of an unexpected type was rejected.
    package static func slotError(_ slot: CFTypeRef) -> AXError? {

        guard CFGetTypeID(slot) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(slot, to: AXValue.self)
        guard AXValueGetType(value) == .axError else { return nil }
        var code: Int32 = 0
        guard AXValueGetValue(value, .axError, &code) else { return nil }
        return AXError(rawValue: code)
    }

    /// A required attribute keeps the outcome its single read had: an error
    /// slot fails the whole pass naming that attribute and carrying that
    /// AXError, and a slot of an unexpected type fails it with AXError 0, which
    /// is what a single read whose value would not cast already reported.
    private static func requiredSlot<Value>(
        _ slot   : CFTypeRef?,
        processID: Int32,
        attribute: String
    ) -> Result<Value, CrossCheckedSurfaceReadFailure> {

        func unavailable(_ error: AXError) -> Result<Value, CrossCheckedSurfaceReadFailure> {
            .failure(.attributeUnavailable(
                processID: processID,
                attribute: attribute,
                error    : error.rawValue
            ))
        }
        guard let slot else { return unavailable(.success) }
        if let error = slotError(slot) { return unavailable(error) }
        guard let value = slot as? Value else { return unavailable(.success) }
        return .success(value)
    }

    /// An optional attribute keeps the outcome its single read had: an error
    /// slot leaves the field nil and the pass continues.
    private static func optionalBool(_ slot: CFTypeRef?) -> Bool? {

        guard let slot, slotError(slot) == nil else { return nil }
        return (slot as? NSNumber)?.boolValue
    }

    /// The window level AppKit reserves for modal panels.
    static let modalPanelLevel = Int(CGWindowLevelForKey(.modalPanelWindow))

    /// Whether a dialog the application runs modally is modal although its
    /// `AXModal` says otherwise.
    ///
    /// Photoshop's Duplicate Layer, measured on 30/09/2026, is an `AXWindow`
    /// with subrole `AXDialog`, seven children, `AXModal` false, at window level
    /// 8 and the application's focused window, and Photoshop answered nothing
    /// else while it was open: every menu command was ignored. The seat held the
    /// dialog and kept the document as the scene; a prepared Escape sent to the
    /// document then crashed Photoshop. The level alone is no evidence: macOS's
    /// 66 by 20 point traffic light overlay was read at level 8 over such a
    /// dialog. That overlay is never the application's focused window, and it
    /// is born with no role, so the three together are what this reads.
    static func runsModally(_ record: AccessibilitySurfaceRecord, level: Int) -> Bool {
        record.isModal != true
            && record.role == .dialog
            && record.isFocused == true
            && level == modalPanelLevel
    }

    /// Whether this surface is modal, from the attribute when it answers and
    /// from the role when the role already carries the fact.
    ///
    /// `AXModal` is required of window elements, and a surface that cannot say
    /// stays unknown: the same pass then cannot establish that choosing another
    /// window is safe, and `visibility(of:serverSurface:)` answers uncertain on
    /// it. That rule is unchanged and an `AXWindow` with no readable `AXModal`
    /// is exactly as uncertain as it was.
    ///
    /// One role answers for itself. An `AXSheet` is modal to the window it is
    /// attached to by construction: that is what a sheet is in AppKit and what
    /// the accessibility vocabulary means by the role, and `parentWindowNumber`
    /// already says the same thing from the other side, that for a sheet
    /// `AXWindow` is the containing ordinary window. Asking a sheet whether it
    /// is modal is asking it to repeat its own kind, and it does not answer:
    /// measured on 26A5425a, Slack's open and save panel reports `AXModal`
    /// unread while the window server shows the surface on screen at its own
    /// rect, so the seat could observe nothing for a panel that was plainly
    /// there.
    ///
    /// The attribute still wins where it is readable, so a sheet that answers
    /// is believed rather than overridden. A drawer is deliberately not here: it
    /// sits beside its window and blocks nothing, and the two share a branch in
    /// `windowFacts` for their empty subrole and for nothing else.
    package static func modality(of slot: CFTypeRef?, roleName: String) -> Bool? {

        if let read = optionalBool(slot) { return read }
        return roleName == (kAXSheetRole as String) ? true : nil
    }

    private static func relatedElement(_ slot: CFTypeRef?) -> AXUIElement? {

        guard let slot, slotError(slot) == nil,
              CFGetTypeID(slot) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(slot, to: AXUIElement.self)
    }

    private static func nativeResult<Value>(
        _ result  : Result<Value, BoundedAccessibilityRead.Failure>,
        processID : Int32,
        attribute : String
    ) -> Result<Value, CrossCheckedSurfaceReadFailure> {

        switch result {
            case .success(let value): return .success(value)
            case .failure(let failure):
                if failure.attempts == 0 { return .failure(.passDeadlineExpired) }
                return .failure(.attributeUnavailable(
                    processID: processID,
                    attribute: attribute,
                    error: failure.error.rawValue
                ))
        }
    }

    /// AX exposes the focused window while an application is active and the
    /// main document window even while it is inactive. A unique focused window
    /// is the stronger statement; otherwise a unique main window is enough.
    /// Contradictory duplicates produce no order claim.
    private static func currentApplicationTarget(
        in records: [AccessibilitySurfaceRecord]
    ) -> AccessibilitySurfaceRecord? {

        let focused = records.filter { $0.isFocused == true }
        if focused.count == 1 { return focused[0] }
        if focused.count > 1 { return nil }

        let main = records.filter { $0.isMain == true }
        return main.count == 1 ? main[0] : nil
    }

    /// The window this modal surface is attached to, read from the two
    /// attributes that answer it, nearest relation first.
    ///
    /// `AXParent` is asked before `AXWindow` because a dialog opened from
    /// inside another dialog is what this pass has to be able to see: `AXWindow`
    /// is documented as the containing ordinary window, so a sheet presented on
    /// a sheet resolves through it to the host and the middle surface is lost,
    /// while `AXParent` of a sheet is the surface it was presented on. Both are
    /// the element's own answer about itself; neither is inferred.
    ///
    /// A parent that resolves to this surface is discarded rather than recorded
    /// as parentage, which is what an ordinary top-level window generally
    /// answers for `AXWindow`.
    private static func parentWindowNumber(
        of window           : AXUIElement,
        ownedBy processID   : Int32,
        excluding selfNumber: Int,
        deadlineNanoseconds : UInt64,
        windowNumbers       : AccessibilityWindowNumberCache
    ) -> Int? {

        for attribute in [kAXParentAttribute, kAXWindowAttribute] {
            guard let number = windowNumberAttribute(
                window,
                attribute,
                ownedBy: processID,
                deadlineNanoseconds: deadlineNanoseconds,
                windowNumbers: windowNumbers
            ),
                  number != selfNumber
            else { continue }
            return number
        }
        return nil
    }

    /// Resolves an attribute that answers a related window element, then that
    /// element's Window ID. Only the second half is cached: which window the
    /// attribute names is modality, which is state, and is read every pass.
    private static func windowNumberAttribute(
        _ element          : AXUIElement,
        _ name             : String,
        ownedBy processID  : Int32,
        deadlineNanoseconds: UInt64,
        windowNumbers      : AccessibilityWindowNumberCache
    ) -> Int? {

        let related: Result<AXUIElement, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(
                deadlineNanoseconds: deadlineNanoseconds,
                recoversCannotComplete: false
            ) { timeout in
                AXUIElementSetMessagingTimeout(element, timeout)
                var raw: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
                guard error == .success, let raw,
                      CFGetTypeID(raw) == AXUIElementGetTypeID()
                else { return (error, nil) }
                return (.success, unsafeDowncast(raw, to: AXUIElement.self))
            }
        guard case .success(let related) = related else { return nil }
        return windowNumber(
            of: related,
            ownedBy: processID,
            deadlineNanoseconds: deadlineNanoseconds,
            windowNumbers: windowNumbers
        )
    }

    private static func windowNumber(
        of element         : AXUIElement,
        ownedBy processID  : Int32,
        deadlineNanoseconds: UInt64,
        windowNumbers      : AccessibilityWindowNumberCache
    ) -> Int? {

        let number: Result<Int, BoundedAccessibilityRead.Failure> =
            windowNumbers.windowNumber(of: element, ownedBy: processID) {
                BoundedAccessibilityRead.value(
                    deadlineNanoseconds: deadlineNanoseconds,
                    recoversCannotComplete: false
                ) { timeout in
                    AXUIElementSetMessagingTimeout(element, timeout)
                    guard let value = WindowRelocator.windowNumber(of: element) else {
                        return (.cannotComplete, nil)
                    }
                    return (.success, value)
                }
            }
        return try? number.get()
    }

    /// The role a record is claimed with: the one it read, except for the 66 by
    /// 20 point overlay `role(named:subrole:...)` describes, which is claimed a
    /// decoration.
    ///
    /// Measured again on 05 and 06/10/2026 in DaVinci Resolve and in TextEdit,
    /// level 0, subrole `AXDialog`, not modal, a new Window ID each time, seen
    /// after a text field took focus. Read as a dialog it became a candidate
    /// beside the document and the selection asked for an explicit choice at
    /// every observation. Nothing else this reader takes separates it from a
    /// dialog, so the size decides; a modal answers for itself whatever its size.
    package static func role(
        of record   : AccessibilitySurfaceRecord,
        readAs role : SurfaceRole,
        frame       : CGRect
    ) -> SurfaceRole {
        // ponytail: a size class from the measured 66x20 point surface; replace it with a
        // native trait of that window (title, identifier) once one is read and measured.
        guard role == .dialog, record.isModal != true,
              frame.width <= 80, frame.height <= 24
        else { return role }
        return .decoration
    }

    private static func visibility(
        of record   : AccessibilitySurfaceRecord,
        serverSurface: WindowSurface
    ) -> SurfaceVisibility {

        // AXModal is required for window elements. If it could not be read, the
        // same pass cannot establish that choosing another window is safe.
        guard record.isModal != nil else { return .uncertain }
        if record.isMinimised == true { return .minimisedEstablished }
        if record.appIsHidden {
            return serverSurface.isVisible ? .uncertain : .hiddenEstablished
        }
        return serverSurface.isVisible ? .visibleInteractive : .uncertain
    }

    private static func mismatchReason(
        accessibilityOnly: Set<SurfaceKey>,
        serverDuplicates : Set<SurfaceKey>,
        axDuplicates     : Set<SurfaceKey>,
        retainedDuplicates: Set<SurfaceKey>,
        retainedOnScreenWithoutAX: Set<SurfaceKey>
    ) -> String {

        func numbers(_ keys: Set<SurfaceKey>) -> String {
            keys.sorted().prefix(8).map { "\($0.processID):\($0.windowNumber)" }.joined(separator: ",")
        }
        return "WindowServer did not attest every requested AXWindows row"
            + " (axOnly=[\(numbers(accessibilityOnly))],"
            + " serverDuplicates=[\(numbers(serverDuplicates))],"
            + " axDuplicates=[\(numbers(axDuplicates))],"
            + " retainedDuplicates=[\(numbers(retainedDuplicates))],"
            + " retainedOnScreenWithoutAX=[\(numbers(retainedOnScreenWithoutAX))])"
    }
}
