//
//  CrossCheckedSurfaceReader.swift
//  AgentSeatKit
//
//  Created by OpenAI Codex on 16/09/2026.
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
    case windowIdentityUnavailable(processID: Int32, index: Int)
    case windowServerUnavailable

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
            case .windowIdentityUnavailable(let processID, let index):
                "Accessibility window \(index) for process \(processID) has no readable "
                    + "WindowServer identity"
            case .windowServerUnavailable:
                "The WindowServer optionAll list could not be read"
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
/// WindowServer `.optionAll` row for the same process lifetime.
///
/// AX supplies the positive scope plus role, minimisation, modality, parentage
/// and the application's focused/main window. WindowServer supplies attested
/// identity, geometry and on-screen state for that scope. Its additional
/// same-process surfaces are not promoted into windows merely because their PID
/// matches. A missing AX counterpart or duplicate identifier marks the
/// inventory incomplete. A semantic AX attribute that cannot be read leaves its
/// role absent or its visibility uncertain, so selection still closes the input
/// gate without misreporting the membership pass.
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
        retaining retainedIdentities: Set<WindowIdentity> = []
    ) -> Result<AssignedSurfaceSnapshot, CrossCheckedSurfaceReadFailure> {

        guard Permissions.preflight(.accessibility) else {
            return .failure(.accessibilityPermissionMissing)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ BoundedAccessibilityRead.passNanoseconds
        let accessibility: [AccessibilitySurfaceRecord]
        switch accessibilityRecords(ownedBy: processIDs, deadlineNanoseconds: deadline) {
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
        guard let serverSurfaces = WindowServerProbe.surfaces(matching: requested) else {
            return .failure(.windowServerUnavailable)
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

        let retainedWithoutAX = Set(retainedByKey.keys).subtracting(axKeys)
        let withdrawn = retainedWithoutAX.filter { key in
            guard !retainedDuplicates.contains(key),
                  !serverDuplicates.contains(key),
                  let expected = retainedByKey[key],
                  let surface = serverByKey[key],
                  surface.reference.identity == expected
            else { return false }
            return !surface.isVisible
        }
        let retainedOnScreenWithoutAX = retainedWithoutAX.filter { key in
            guard !retainedDuplicates.contains(key),
                  !serverDuplicates.contains(key),
                  let expected = retainedByKey[key],
                  let surface = serverByKey[key],
                  surface.reference.identity == expected
            else { return false }
            return surface.isVisible
        }

        let isExact = axKeys.isSubset(of: serverKeys)
            && serverDuplicates.isDisjoint(with: axKeys)
            && axDuplicates.isEmpty
            && retainedDuplicates.isEmpty
            && retainedOnScreenWithoutAX.isEmpty

        var identitiesByKey: [SurfaceKey: WindowIdentity] = [:]
        for key in matched {
            identitiesByKey[key] = serverByKey[key]?.reference.identity
        }

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
                        role      : role,
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

            if record.isModal == true {
                claims.modals.append(
                    ModalRelationClaim(
                        modal     : identity,
                        scope     : parent.map(ModalScope.window) ?? .application,
                        provenance: .qualifiedModalAttestation
                    )
                )
            }
        }

        for key in withdrawn.sorted() {
            guard let surface = serverByKey[key],
                  let identity = surface.reference.identity
            else { continue }

            rows.append(
                SurfaceInventoryReading.Row(
                    surface   : surface,
                    provenance: .windowServerAttestedIdentity
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
                retainedOnScreenWithoutAX: retainedOnScreenWithoutAX
            ))

        return AssignedSurfaceSnapshot(
            inventory: SurfaceInventoryReading(rows: rows, completeness: completeness),
            claims   : claims,
            // Reported, not acted on: how long a surface has been outside the
            // application's own scope is not something one pass can know.
            withdrawnByApplication: retainedOnScreenWithoutAX
                .sorted { $0.windowNumber < $1.windowNumber }
                .compactMap { retainedByKey[$0] }
        )
    }

    private static func accessibilityRecords(
        ownedBy processIDs : Set<Int32>,
        deadlineNanoseconds: UInt64
    ) -> Result<[AccessibilitySurfaceRecord], CrossCheckedSurfaceReadFailure> {

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
            let mainWindowNumber = windowNumberAttribute(
                application,
                kAXMainWindowAttribute,
                deadlineNanoseconds: deadlineNanoseconds
            )
            let focusedWindowNumber = windowNumberAttribute(
                application,
                kAXFocusedWindowAttribute,
                deadlineNanoseconds: deadlineNanoseconds
            )

            for (index, window) in windows.enumerated() {
                let facts: RequiredWindowFacts
                switch requiredWindowFacts(
                    window,
                    processID: processID,
                    index: index,
                    deadlineNanoseconds: deadlineNanoseconds
                ) {
                    case .success(let value): facts = value
                    case .failure(let failure): return .failure(failure)
                }
                let isMinimised = optionalBoolAttribute(
                    window,
                    kAXMinimizedAttribute,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                let isModal = optionalBoolAttribute(
                    window,
                    kAXModalAttribute,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                records.append(
                    AccessibilitySurfaceRecord(
                        processID   : processID,
                        windowNumber: facts.windowNumber,
                        role        : facts.role,
                        isMinimised : isMinimised,
                        isModal     : isModal,
                        isMain      : mainWindowNumber.map { $0 == facts.windowNumber },
                        isFocused   : focusedWindowNumber.map { $0 == facts.windowNumber },
                        parentWindowNumber: isModal == true ? parentWindowNumber(
                            of: window,
                            excluding: facts.windowNumber,
                            deadlineNanoseconds: deadlineNanoseconds
                        ) : nil,
                        appIsHidden : running.isHidden
                    )
                )
            }
        }
        guard DispatchTime.now().uptimeNanoseconds <= deadlineNanoseconds else {
            return .failure(.passDeadlineExpired)
        }
        return .success(records)
    }

    private struct RequiredWindowFacts {
        let windowNumber: Int
        let role        : SurfaceRole?
    }

    private static func requiredWindowFacts(
        _ window            : AXUIElement,
        processID           : Int32,
        index               : Int,
        deadlineNanoseconds : UInt64
    ) -> Result<RequiredWindowFacts, CrossCheckedSurfaceReadFailure> {

        let identity: Result<Int, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(deadlineNanoseconds: deadlineNanoseconds) { timeout in
                AXUIElementSetMessagingTimeout(window, timeout)
                guard let windowNumber = WindowRelocator.windowNumber(of: window) else {
                    return (.cannotComplete, nil)
                }
                return (.success, windowNumber)
            }
        let windowNumber: Int
        switch identity {
            case .success(let value): windowNumber = value
            case .failure(let failure):
                if failure.attempts == 0 { return .failure(.passDeadlineExpired) }
                return .failure(.windowIdentityUnavailable(processID: processID, index: index))
        }

        let roleName: String
        switch requiredAttribute(
            window,
            name: kAXRoleAttribute,
            processID: processID,
            deadlineNanoseconds: deadlineNanoseconds
        ) as Result<String, CrossCheckedSurfaceReadFailure> {
            case .success(let value): roleName = value
            case .failure(let failure): return .failure(failure)
        }

        if roleName == (kAXSheetRole as String) {
            return .success(RequiredWindowFacts(windowNumber: windowNumber, role: .dialog))
        }
        if roleName == (kAXDrawerRole as String) {
            return .success(RequiredWindowFacts(
                windowNumber: windowNumber,
                role        : .interactivePanel
            ))
        }
        guard roleName == (kAXWindowRole as String) else {
            return .success(RequiredWindowFacts(windowNumber: windowNumber, role: nil))
        }

        let subrole: String
        switch requiredAttribute(
            window,
            name: kAXSubroleAttribute,
            processID: processID,
            deadlineNanoseconds: deadlineNanoseconds
        ) as Result<String, CrossCheckedSurfaceReadFailure> {
            case .success(let value): subrole = value
            case .failure(let failure): return .failure(failure)
        }
        let knownRole = role(
            named: roleName,
            subrole: subrole,
            positionIsSettable: false,
            actions: []
        )
        if let knownRole {
            return .success(RequiredWindowFacts(windowNumber: windowNumber, role: knownRole))
        }
        guard subrole == "AXUnknown" else {
            return .success(RequiredWindowFacts(windowNumber: windowNumber, role: nil))
        }

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
        return .success(RequiredWindowFacts(
            windowNumber: windowNumber,
            role: role(
                named: roleName,
                subrole: subrole,
                positionIsSettable: movable,
                actions: actions
            )
        ))
    }

    /// A top-level AX window with an unknown subrole is selectable only when AX
    /// also says it has the two traits Mecum needs from an operable window: its
    /// position is writable and it supports raise. This admits DaVinci's main
    /// window without turning every unknown AX surface into a document.
    package static func role(
        named role        : String,
        subrole           : String?,
        positionIsSettable: Bool,
        actions           : Set<String>
    ) -> SurfaceRole? {

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

    private static func parentWindowNumber(
        of window           : AXUIElement,
        excluding selfNumber: Int,
        deadlineNanoseconds : UInt64
    ) -> Int? {

        // For a sheet or drawer AXWindow is the containing ordinary window.
        // For an ordinary top-level window it generally resolves to itself,
        // which is deliberately discarded rather than recorded as parentage.
        guard let number = windowNumberAttribute(
            window,
            kAXWindowAttribute,
            deadlineNanoseconds: deadlineNanoseconds
        ),
              number != selfNumber
        else { return nil }
        return number
    }

    private static func windowNumberAttribute(
        _ element          : AXUIElement,
        _ name             : String,
        deadlineNanoseconds: UInt64
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

        let number: Result<Int, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(
                deadlineNanoseconds: deadlineNanoseconds,
                recoversCannotComplete: false
            ) { timeout in
                AXUIElementSetMessagingTimeout(related, timeout)
                guard let value = WindowRelocator.windowNumber(of: related) else {
                    return (.cannotComplete, nil)
                }
                return (.success, value)
            }
        return try? number.get()
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

    private static func optionalBoolAttribute(
        _ element          : AXUIElement,
        _ name             : String,
        deadlineNanoseconds: UInt64
    ) -> Bool? {

        let result: Result<Bool, BoundedAccessibilityRead.Failure> =
            BoundedAccessibilityRead.value(
                deadlineNanoseconds: deadlineNanoseconds,
                recoversCannotComplete: true
            ) { timeout in
                AXUIElementSetMessagingTimeout(element, timeout)
                var raw: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
                return (error, (raw as? NSNumber)?.boolValue)
            }
        return try? result.get()
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
        return "WindowServer optionAll did not attest every AXWindows row"
            + " (axOnly=[\(numbers(accessibilityOnly))],"
            + " serverDuplicates=[\(numbers(serverDuplicates))],"
            + " axDuplicates=[\(numbers(axDuplicates))],"
            + " retainedDuplicates=[\(numbers(retainedDuplicates))],"
            + " retainedOnScreenWithoutAX=[\(numbers(retainedOnScreenWithoutAX))])"
    }
}
