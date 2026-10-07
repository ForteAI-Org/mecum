//
//  WindowServerProbe.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Darwin
import PrivateSymbols
import SeatCore
import VirtualScreens

/// WindowServerProbe reads window geometry and order straight from the window
/// server, with no accessibility call anywhere in it.
///
/// It is the kit's **second, independent** witness. A window's own reading of
/// its frame and the window server's are updated at different moments, so a
/// placement confirmed by one alone is not confirmed: every geometric check in
/// the kit takes both, and the recovery path of a seat takes only this one,
/// because it has to keep working while the target's accessibility interface
/// is momentarily unreadable.
///
/// `CGWindowListCopyWindowInfo` allocates a dictionary per window and is by far
/// the most expensive geometry call: 609 of the 787 allocations once measured
/// for one click came from it. Coordinate Commands now pay that cost twice:
/// once before construction and once immediately before the first post. Key
/// Commands keep using `identity(of:)`, whose cached gate and fixed ownership
/// calls do not create a window-list dictionary.
nonisolated public enum WindowServerProbe {

    /// A public-list reading carries the distinction the remote fallback needs:
    /// a missing row may be read through the qualified path, whereas a row that
    /// contradicts its ownership chain or an unavailable public read is a
    /// refusal. Neither is evidence of an unlisted remote window.
    package enum GeometryReading {
        case present(WindowReference)
        case absent
        case refused
    }

    /// SurfaceReadFailure preserves the failing witness. A missing row is a
    /// successful empty reading, whereas a rejected gate or identity is not.
    package enum SurfaceReadFailure: Error, Sendable, Equatable, CustomStringConvertible {
        case facilityUnavailable(FacilityReadiness)
        case listUnavailable
        case invalidWindowNumber(Int)
        case invalidGeometry(windowNumber: Int)
        case identityUnavailable(windowNumber: Int)

        package var description: String {
            switch self {
                case .facilityUnavailable(let readiness):
                    "WindowServer identity facility refused: \(readiness)"
                case .listUnavailable:
                    "WindowServer could not read the requested Window ID descriptions"
                case .invalidWindowNumber(let number):
                    "The requested Window ID \(number) is invalid"
                case .invalidGeometry(let number):
                    "WindowServer reported invalid geometry for Window ID \(number)"
                case .identityUnavailable(let number):
                    "WindowServer could not attest ownership of Window ID \(number)"
            }
        }
    }

    /// The ownership reading keeps an absent public row separate from an
    /// unreadable ownership chain. Consumers deciding whether a panel closed
    /// must never turn an arbitrary failed identity read into destruction.
    public enum IdentityReading {
        case present(WindowIdentity)
        case absent
        case unreadable
    }

    /// The public Process Manager mapping documented by the macOS SDK. Swift 6
    /// no longer imports `ProcessSerialNumber`, so the two-word value crosses
    /// this call as raw storage with the header's exact pointer ABI. It is
    /// module-wide only so the Unit tier can hand the chain its own mapping.
    typealias GetProcessPID = @convention(c) (
        UnsafeRawPointer?,
        UnsafeMutablePointer<Int32>?
    ) -> Int32

    private struct ProcessSerialNumberValue: Equatable {
        var high: UInt32 = 0
        var low : UInt32 = 0
    }

    /// `GetProcessPID` is a documented, deprecated SDK function rather than a
    /// private primitive. Missing it refuses identity resolution; it is never
    /// replaced with a guess from a PID that merely happens to be alive.
    private static let getProcessPID: GetProcessPID? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework"
            + "/Frameworks/HIServices.framework/HIServices"
        guard let image = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let address = dlsym(image, "GetProcessPID")
        else { return nil }
        return unsafeBitCast(address, to: GetProcessPID.self)
    }()

    /// The window server's own reading of one Window ID: owner and frame.
    /// Scoped to the requested id, so a window that is gone answers `nil`
    /// rather than a neighbour's geometry.
    public static func geometry(
        of windowNumber       : Int,
        allowUnvalidatedBuild : Bool = false,
        table                 : SymbolTable = .shared
    ) -> WindowReference? {

        switch geometryReading(
            of: windowNumber,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table: table
        ) {
        case .present(let window): return window
        case .absent, .refused: return nil
        }
    }

    /// The complete result of reading one public WindowServer row. Callers that
    /// can legitimately use the private unlisted path must preserve this state
    /// instead of turning every `nil` from `geometry(of:)` into absence.
    package static func geometryReading(
        of windowNumber       : Int,
        allowUnvalidatedBuild : Bool = false,
        table                 : SymbolTable = .shared
    ) -> GeometryReading {

        let gate = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        guard let windowID = CGWindowID(exactly: windowNumber), windowID != 0,
              let firstIdentity = identity(
                  of         : windowNumber,
                  table      : table,
                  validatedBy: gate
              ),
              let windows = CGWindowListCopyWindowInfo(
                  .optionIncludingWindow,
                  windowID
              ) as? [[String: Any]]
        else { return .refused }
        guard let entry = windows.first(where: { number(of: $0) == windowNumber }) else {
            return .absent
        }
        guard let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
              frame.hasFinitePositiveArea,
              processID == firstIdentity.processID,
              identity(
                  of         : windowNumber,
                  table      : table,
                  validatedBy: gate
              ) == firstIdentity
        else { return .refused }

        return .present(WindowReference(identity: firstIdentity, frame: frame))
    }

    /// The WindowServer ownership chain for one Window ID, read twice and
    /// accepted only when every link agrees.
    ///
    /// `SLSGetWindowOwner` binds the Window ID to its connection,
    /// `SLSGetConnectionPSN` binds that connection to one process lifetime, and
    /// the documented `GetProcessPID` maps that lifetime back to the PID. This
    /// uses no Accessibility API and returns `nil` when any relationship cannot
    /// be proved.
    public static func identity(
        of windowNumber       : Int,
        allowUnvalidatedBuild : Bool = false,
        table                 : SymbolTable = .shared
    ) -> WindowIdentity? {

        let gate = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        return identity(of: windowNumber, table: table, validatedBy: gate)
    }

    /// Reads the identity when possible. A failed qualified owner read remains
    /// unreadable even if the public list has no row: remote content is
    /// deliberately absent from that list, and a transient gate failure is not
    /// proof that a logical surface was destroyed.
    public static func identityReading(
        of windowNumber       : Int,
        wasPubliclyAttested   : Bool = false,
        allowUnvalidatedBuild : Bool = false,
        table                 : SymbolTable = .shared
    ) -> IdentityReading {
        let gate = FacilityGate.current(
            facility: .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table: table
        )
        guard let candidate = CGWindowID(exactly: windowNumber), candidate != 0 else {
            return .unreadable
        }
        if let value = identity(of: windowNumber, table: table, validatedBy: gate) {
            return .present(value)
        }
        // Remote helper content is often absent from the public list, so only
        // a logical proxy this caller previously saw there can be declared
        // destroyed. Read the same scoped public list twice under the live
        // facility gate; a failed owner chain or a list error stays unreadable.
        guard wasPubliclyAttested, gate.mayAct,
              publicRowIsAbsent(windowNumber), publicRowIsAbsent(windowNumber)
        else { return .unreadable }
        return .absent
    }

    private static func publicRowIsAbsent(_ windowNumber: Int) -> Bool {
        guard let windowID = CGWindowID(exactly: windowNumber), windowID != 0,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
        else { return false }
        return !rows.contains { number(of: $0) == windowNumber }
    }

    /// Resolves identity under a gate already evaluated by the owning Facility.
    /// Package clients cache this gate so the per-Command revalidation performs
    /// only the three ownership calls and the documented PID mapping.
    package static func identity(
        of windowNumber: Int,
        table          : SymbolTable,
        validatedBy gate: FacilityGate
    ) -> WindowIdentity? {

        var processes = OwnerProcesses()
        return identity(
            of         : windowNumber,
            table      : table,
            validatedBy: gate,
            memoizing  : &processes
        )
    }

    /// The owner connections already resolved during one call, so the two pure
    /// legs of the chain are paid once each per connection instead of once per
    /// read. It is created by the enumerating call and dies with it: a
    /// connection ID can be handed to a new process after the old one exits, so
    /// a memo that outlived the walk could name a live PID for a dead process,
    /// which is the error this whole type exists to refuse.
    package typealias OwnerProcesses = [Int32: ProcessIdentity]

    /// Resolves identity against a memo of owner connections the calling walk
    /// owns. Both readings of `SLSGetWindowOwner` and their comparison stay:
    /// the owner is the leg that can change underneath a walk, and it is never
    /// memoized. What the memo removes is `SLSGetConnectionPSN` and
    /// `GetProcessPID` behind it, which are a pure function of the connection
    /// for that connection's life: ten windows of one application resolve one
    /// process instead of twenty.
    static func identity(
        of windowNumber : Int,
        table           : SymbolTable,
        validatedBy gate: FacilityGate,
        memoizing processes: inout OwnerProcesses
    ) -> WindowIdentity? {

        guard gate.mayAct,
              let windowID = UInt32(exactly: windowNumber), windowID != 0,
              let mainConnectionID = table.function(
                  .mainConnectionID,
                  as: SymbolABI.MainConnectionID.self
              ),
              let getWindowOwner = table.function(
                  .getWindowOwner,
                  as: SymbolABI.GetWindowOwner.self
              ),
              let getConnectionPSN = table.function(
                  .getConnectionPSN,
                  as: SymbolABI.GetConnectionPSN.self
              ),
              let getProcessPID
        else { return nil }

        let connectionID = mainConnectionID()
        guard connectionID != 0,
              let first = identity(
                  windowNumber    : windowID,
                  connectionID    : connectionID,
                  getWindowOwner  : getWindowOwner,
                  getConnectionPSN: getConnectionPSN,
                  getProcessPID   : getProcessPID,
                  memoizing       : &processes
              ),
              let second = identity(
                  windowNumber    : windowID,
                  connectionID    : connectionID,
                  getWindowOwner  : getWindowOwner,
                  getConnectionPSN: getConnectionPSN,
                  getProcessPID   : getProcessPID,
                  memoizing       : &processes
              ),
              first == second
        else { return nil }

        return first
    }

    /// Maps an already-attested process serial number through the exact cached
    /// SDK function used by `identity(of:)`. SeatBench uses this package-only
    /// read to measure the two documented PID mappings separately from the kit's
    /// ownership checks. It adds no alternative identity path: failure stays
    /// `nil`, and callers still have to compare the answer with the attested PID.
    package static func mappedProcessID(of process: ProcessIdentity) -> Int32? {
        guard let getProcessPID else { return nil }

        var serialNumber = ProcessSerialNumberValue(
            high: process.serialNumberHigh,
            low : process.serialNumberLow
        )
        var processID: Int32 = 0
        let result = withUnsafePointer(to: &serialNumber) { pointer in
            getProcessPID(UnsafeRawPointer(pointer), &processID)
        }
        guard result == 0, processID > 0 else { return nil }
        return processID
    }

    /// Attests one row of a WindowServer list under a gate the caller evaluated
    /// once for the whole list. This avoids a second list allocation per window
    /// while still binding every row to its owner connection and process life.
    package static func reference(
        processID       : Int32,
        windowNumber    : Int,
        frame           : CGRect,
        table           : SymbolTable,
        validatedBy gate: FacilityGate
    ) -> WindowReference? {

        var processes = OwnerProcesses()
        return reference(
            processID   : processID,
            windowNumber: windowNumber,
            frame       : frame,
            table       : table,
            validatedBy : gate,
            memoizing   : &processes
        )
    }

    /// The same attestation, against the memo of the walk that is enumerating.
    /// The walk owns the memo and passes it to every row, so an enumeration of
    /// `n` windows pays one process resolution per distinct owner connection
    /// instead of one per row; both owner readings and their comparison stay.
    package static func reference(
        processID       : Int32,
        windowNumber    : Int,
        frame           : CGRect,
        table           : SymbolTable,
        validatedBy gate: FacilityGate,
        memoizing processes: inout OwnerProcesses
    ) -> WindowReference? {

        guard let identity = identity(
            of         : windowNumber,
            table      : table,
            validatedBy: gate,
            memoizing  : &processes
        ), identity.processID == processID else { return nil }
        return WindowReference(identity: identity, frame: frame)
    }

    /// This window's place in the front to back order, or `nil` when it is not
    /// on screen. The index spans every display, so it answers "is this in
    /// front of that", never "is this on stage".
    public static func orderIndex(of windowNumber: Int) -> Int? {
        orderedWindows()?.firstIndex { number(of: $0) == windowNumber }
    }

    /// The level a contextual menu is drawn at, asked of the system rather than
    /// written down. It is 101 on every build measured, and the reason it is
    /// read is that a constant copied out of a header is exactly the kind of
    /// fact this package has already caught being wrong.
    public static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// The level the desktop is drawn at, asked of the system for the same
    /// reason as the one above.
    ///
    /// A window at or below it is behind every ordinary window, the person's
    /// own included, so it cannot be on top of their work. The Finder draws one
    /// of these per display and always has: measured on 26A5425a with the Finder
    /// adopted, pid 487 owned Window ID 39 at (0, 0, 1512, 982) on the physical
    /// display and Window ID 43302 at (1512, 982, 2560, 1440) on the virtual
    /// one, both at level -2147483603, which is this key.
    public static let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

    /// Every window this process owns that is drawn at the pop up menu level
    /// and is on screen: the whole oracle for "did a contextual menu open".
    ///
    /// It is here and not in `geometry(of:)` because a menu has no Window ID
    /// anybody knew in advance, so it cannot be looked up: it is found by owner
    /// and level or it is not found at all. And it is the **only** oracle: an
    /// open contextual menu is not in the target's accessibility tree, under
    /// the application or under the window, on either family measured, so a
    /// reading that asks the tree answers "no menu" for a menu that is on the
    /// screen. That reading is what produced this package's earlier verdict
    /// that a background application opens no menu at all.
    ///
    /// The on-screen filter is deliberate and it is what makes the answer
    /// positive evidence: the window server keeps menu-level windows of past
    /// menus around off screen, and one of those is not a menu the caller just
    /// opened.
    public static func menuWindows(ownedBy processID: Int32) -> [WindowReference] {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        return windows.compactMap { description in
            guard owner(of: description) == processID,
                  layer(of: description) == popUpMenuLevel,
                  let windowNumber = number(of: description),
                  let window = geometry(of: windowNumber),
                  window.processID == processID
            else { return nil }
            return window
        }
        .sorted { $0.windowNumber < $1.windowNumber }
    }

    /// Every on-screen window owned by one of these processes, attested row by
    /// row, with the level and the visibility the same reading reported.
    ///
    /// `nil` is a reading that failed and it is not the same answer as an empty
    /// list. A process that shows nothing and a window server that did not
    /// answer need different decisions from the caller, and replying `[]` to
    /// both is how a watcher concludes that every window of an application has
    /// just vanished.
    ///
    /// `.optionOnScreenOnly` is load bearing here and not an optimisation. A Qt
    /// application was measured holding dozens of real, titled windows that the
    /// window server knows about and has never shown, built long before the
    /// person asks for them: with `.optionAll` every one of those reads as a
    /// window that just appeared, and opening one of them for real produces no
    /// difference in the list at all.
    ///
    /// Attestation is per row, under one gate evaluated once and one memo of
    /// owner connections, so a list of `n` windows costs one window list
    /// allocation, `2n` owner readings and one process resolution per distinct
    /// owner connection, instead of the `6n` window server round trips a chain
    /// resolved from scratch on every row costs.
    public static func surfaces(
        ownedBy processIDs   : Set<Int32>,
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared
    ) -> [WindowSurface]? {

        guard !processIDs.isEmpty else { return [] }

        let gate = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        guard gate.mayAct else { return nil }
        guard let descriptions = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var processes = OwnerProcesses()
        var surfaces: [WindowSurface] = []
        for description in descriptions {
            guard let processID = owner(of: description), processIDs.contains(processID),
                  let windowNumber = number(of: description),
                  let frame = frame(of: description),
                  let reference = reference(
                      processID       : processID,
                      windowNumber    : windowNumber,
                      frame           : frame,
                      table           : table,
                      validatedBy     : gate,
                      memoizing       : &processes
                  )
            else { continue }

            surfaces.append(
                WindowSurface(
                    reference: reference,
                    level    : layer(of: description) ?? 0,
                    isVisible: isOnScreen(description) && alpha(of: description) > 0
                        && frame.width > 0 && frame.height > 0
                )
            )
        }
        return surfaces
    }

    /// The WindowServer rows matching application windows already named by AX,
    /// including hidden and minimised windows, with every matched row
    /// identity-attested.
    ///
    /// This is deliberately separate from `surfaces(ownedBy:)`: the whole window
    /// list contains internal surfaces that were never shown and is not by
    /// itself evidence that a row is a user-facing application window.
    /// `AXWindows` supplies the positive scope; this pass independently attests
    /// every row in that scope. Extra rows of the same process are not parsed or
    /// promoted into assignment membership merely because their PID matches, and
    /// the owner of every returned row is still compared with the process that
    /// asked for it, so a Window ID handed on to somebody else reads as absent.
    ///
    /// The scope is asked of the window server rather than read whole and
    /// filtered afterwards. `.optionAll` was measured at 477 rows to reach the
    /// handful the caller named, and the call is spent waiting on the window
    /// server rather than working: 0.27 ms of CPU inside 0.88 ms of wall, warm.
    ///
    /// A requested row that is absent remains absent for the caller to reject.
    /// A requested row that is present but cannot be parsed or attested fails
    /// the whole reading rather than silently shrinking the AX inventory.
    public static func surfaces(
        matching windowNumbersByProcess: [Int32: Set<Int>],
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared
    ) -> [WindowSurface]? {
        try? surfaceReading(
            matching             : windowNumbersByProcess,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        ).get()
    }

    /// The scoped reading with its cause preserved for inventory diagnostics.
    package static func surfaceReading(
        matching windowNumbersByProcess: [Int32: Set<Int>],
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared
    ) -> Result<[WindowSurface], SurfaceReadFailure> {
        let gate = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        var processes = OwnerProcesses()
        return readSurfaces(
            matching : windowNumbersByProcess,
            gate     : gate,
            read     : { descriptions(ofWindowIDs: $0) },
            attesting: { processID, windowNumber, frame in
                reference(
                    processID       : processID,
                    windowNumber    : windowNumber,
                    frame           : frame,
                    table           : table,
                    validatedBy     : gate,
                    memoizing       : &processes
                )
            }
        )
    }

    /// The parsing boundary. Tests can distinguish a damaged reading from an
    /// absent window without calling WindowServer or changing permissions.
    static func readSurfaces(
        matching windowNumbersByProcess: [Int32: Set<Int>],
        gate     : FacilityGate,
        read     : ([CGWindowID]) -> [[String: Any]]?,
        attesting: (Int32, Int, CGRect) -> WindowReference?
    ) -> Result<[WindowSurface], SurfaceReadFailure> {
        guard gate.mayAct else { return .failure(.facilityUnavailable(gate.readiness)) }
        guard !windowNumbersByProcess.isEmpty else { return .success([]) }

        var windowIDs: Set<CGWindowID> = []
        for numbers in windowNumbersByProcess.values {
            for number in numbers {
                guard let windowID = CGWindowID(exactly: number), windowID != 0 else {
                    return .failure(.invalidWindowNumber(number))
                }
                windowIDs.insert(windowID)
            }
        }
        guard let descriptions = read(Array(windowIDs)) else {
            return .failure(.listUnavailable)
        }

        var result: [WindowSurface] = []
        for description in descriptions {
            guard let processID = owner(of: description),
                  let requestedNumbers = windowNumbersByProcess[processID],
                  let windowNumber = number(of: description),
                  requestedNumbers.contains(windowNumber)
            else { continue }
            guard let frame = frame(of: description),
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width >= 0, frame.size.height >= 0
            else {
                return .failure(.invalidGeometry(windowNumber: windowNumber))
            }
            guard let reference = attesting(processID, windowNumber, frame),
                  reference.processID == processID,
                  reference.windowNumber == windowNumber,
                  reference.frame == frame
            else {
                return .failure(.identityUnavailable(windowNumber: windowNumber))
            }
            result.append(WindowSurface(
                reference: reference,
                level    : layer(of: description) ?? 0,
                isVisible: reportedOnScreen(description) == true && alpha(of: description) > 0
                    && frame.width > 0 && frame.height > 0
            ))
        }
        return .success(result)
    }

    /// The frontmost normal-layer window whose frame reaches a display. It is
    /// how a Seat Host asks which window is on stage on the Virtual Display
    /// without asking Stage Manager anything.
    public static func frontmostWindow(onDisplayBounds displayBounds: CGRect) -> Int? {
        orderedWindows()?.first { description in
            guard layer(of: description) == 0, let bounds = frame(of: description) else {
                return false
            }
            let intersection = bounds.intersection(displayBounds)
            return intersection.width > 1 && intersection.height > 1
        }
        .flatMap(number(of:))
    }

    /// The frontmost normal-layer window of a process. Its only use is as the
    /// handle the identity chain needs: `SLSGetWindowOwner` on it yields the
    /// process serial number the two Preparation records are addressed to.
    public static func frontWindowNumber(ownedBy processID: Int32) -> Int? {
        orderedWindows()?.first { description in
            owner(of: description) == processID && layer(of: description) == 0
        }
        .flatMap(number(of:))
    }

    /// Whether the target window sits behind the person's frontmost window.
    /// `nil` when either window is not in the on-screen list, which is a
    /// missing reading and not a `false`: a check that read "not behind" from
    /// an absent window would fail a seat for a window that was merely being
    /// redrawn.
    public static func isBehindFrontmostWindow(
        windowNumber: Int,
        ownedBy processID: Int32
    ) -> Bool? {

        guard let windows = orderedWindows(),
              let targetIndex = windows.firstIndex(where: { number(of: $0) == windowNumber }),
              let userIndex = windows.firstIndex(where: {
                  owner(of: $0) == processID && layer(of: $0) == 0
              })
        else { return nil }

        // The list runs front to back, so a larger index is further back.
        return targetIndex > userIndex
    }

    /// An AppKit point (origin bottom left of its own screen) as a Quartz point
    /// (origin top left of the main display).
    ///
    /// The conversion is per screen and not against the main display's height,
    /// because with more than one display those differ and the difference is
    /// exactly the offset that puts a click on the wrong screen. The fallback
    /// for a point on no screen at all flips against the first screen, which is
    /// wrong by the same offset and says so: it exists so a caller gets a
    /// number instead of a crash.
    @MainActor
    public static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let displayID = ScreenRegistration.displayID(of: screen)
        else {
            let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
            return CGPoint(x: point.x, y: mainHeight - point.y)
        }

        let bounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: bounds.minX + point.x - screen.frame.minX,
            y: bounds.minY + screen.frame.maxY - point.y
        )
    }

    /// Whether the window server still lists this window among the ones on the
    /// Space that is on screen.
    ///
    /// A window in native fullscreen has a Space of its own, and this is the
    /// public reading of "the person is looking at something else". Measured on
    /// 26A428: after the focus moves away it goes false 330 ms later with Stage
    /// Manager off and 513 ms later with it on, and the same reading is what
    /// `AXWindows` stops answering for at exactly that moment.
    ///
    /// It is deliberately not "is this window alive". A window that was
    /// destroyed also answers false, and the caller that needs the difference
    /// asks `geometry(of:)`, which is scoped to the id.
    public static func isOnTheActiveSpace(windowNumber: Int) -> Bool {
        orderedWindows()?.contains { number(of: $0) == windowNumber } ?? false
    }

    // MARK: Reading one entry of the list

    /// The description rows for exactly these Window IDs, one window server
    /// call wide instead of the whole machine. A requested ID nothing owns is
    /// simply not in the answer, which is the absence the caller rejects, and
    /// the rows carry the same keys the full list carries, `kCGWindowIsOnscreen`
    /// included and present on exactly the same windows.
    ///
    /// The IDs cross as raw values in a `CFArray` built with no callbacks, the
    /// shape `CGWindowListCreate` returns and this call reads back; a `CFNumber`
    /// would be read as a Window ID of its own address. They are widened to
    /// pointer size first, because a `UInt32` array has the wrong stride for the
    /// slots `CFArrayCreate` copies.
    public static func descriptions(ofWindowIDs windowIDs: [CGWindowID]) -> [[String: Any]]? {
        var values = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let requested = values.withUnsafeMutableBufferPointer({ buffer in
            CFArrayCreate(kCFAllocatorDefault, buffer.baseAddress, buffer.count, nil)
        }) else { return nil }

        return CGWindowListCreateDescriptionFromArray(requested) as? [[String: Any]]
    }

    private static func orderedWindows() -> [[String: Any]]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    }

    private static func number(of description: [String: Any]) -> Int? {
        (description[kCGWindowNumber as String] as? NSNumber)?.intValue
    }

    private static func owner(of description: [String: Any]) -> Int32? {
        (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    private static func layer(of description: [String: Any]) -> Int? {
        (description[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    private static func alpha(of description: [String: Any]) -> Double {
        (description[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    }

    /// Absent means on screen: the list was asked for on-screen windows, and a
    /// row without the key is not evidence that the server hid it.
    private static func isOnScreen(_ description: [String: Any]) -> Bool {
        (description[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
    }

    /// A list that was not asked for on-screen windows does not itself establish
    /// that a row is on screen, so an absent flag stays false on that path
    /// instead of inheriting the on-screen-list default above. The window server
    /// writes the key on the same windows whether the rows are asked for by ID
    /// or read whole.
    private static func reportedOnScreen(_ description: [String: Any]) -> Bool? {
        (description[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
    }

    private static func frame(of description: [String: Any]) -> CGRect? {
        guard let rawBounds = description[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
    }

    /// One reading of the chain, with the process behind the owner connection
    /// taken from the memo when the walk has already proved it. It is internal
    /// rather than private so the Unit tier can drive it with its own three
    /// functions and compare the memoized answer with the unmemoized one; no
    /// shipping caller reaches it, and it still refuses everything it refused.
    static func identity(
        windowNumber    : UInt32,
        connectionID    : Int32,
        getWindowOwner  : SymbolABI.GetWindowOwner,
        getConnectionPSN: SymbolABI.GetConnectionPSN,
        getProcessPID   : GetProcessPID,
        memoizing processes: inout OwnerProcesses
    ) -> WindowIdentity? {

        var ownerConnectionID: Int32 = 0
        guard getWindowOwner(connectionID, windowNumber, &ownerConnectionID) == 0,
              ownerConnectionID != 0
        else { return nil }

        if let process = processes[ownerConnectionID] {
            return WindowIdentity(
                process          : process,
                windowNumber     : Int(windowNumber),
                ownerConnectionID: ownerConnectionID
            )
        }

        var serialNumber = ProcessSerialNumberValue()
        let serialResult = withUnsafeMutablePointer(to: &serialNumber) { pointer in
            getConnectionPSN(ownerConnectionID, UnsafeMutableRawPointer(pointer))
        }
        guard serialResult == 0 else { return nil }

        var processID: Int32 = 0
        let processResult = withUnsafePointer(to: &serialNumber) { pointer in
            getProcessPID(UnsafeRawPointer(pointer), &processID)
        }
        guard processResult == 0, processID > 0 else { return nil }

        let process = ProcessIdentity(
            processID       : processID,
            serialNumberHigh: serialNumber.high,
            serialNumberLow : serialNumber.low
        )
        processes[ownerConnectionID] = process

        return WindowIdentity(
            process          : process,
            windowNumber     : Int(windowNumber),
            ownerConnectionID: ownerConnectionID
        )
    }
}
